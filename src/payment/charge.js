// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
const { context, propagation, trace, metrics, SpanStatusCode } = require('@opentelemetry/api');
const cardValidator = require('simple-card-validator');
const { v4: uuidv4 } = require('uuid');

const { OpenFeature } = require('@openfeature/server-sdk');
const { FlagdProvider } = require('@openfeature/flagd-provider');
const flagProvider = new FlagdProvider();

const logger = require('./logger');
const pool = require('./database');
const tracer = trace.getTracer('payment');
const meter = metrics.getMeter('payment');
const transactionsCounter = meter.createCounter('app.payment.transactions');

const LOYALTY_LEVEL = ['platinum', 'gold', 'silver', 'bronze'];

// ---------------------------------------------------------------------------
// "Bad deployment" scenario (payment 2.0.3).
//
// When PAYMENT_ITEM_LOOKUPS is set, charge() stops writing the transaction with
// a single INSERT and instead performs a per-item lookup loop first - the
// classic N+1 a careless refactor introduces. Every query is a primary-key hit
// against a 50-row table, so each one is sub-millisecond and the database is
// never at risk; the damage is done by doing 50-100 of them sequentially per
// charge, which is exactly what makes N+1 hard to spot in code review and
// obvious in a trace.
//
// Off unless the env var is set. No flagd involvement: this is meant to look
// like a deployment, not a feature flag.
// ---------------------------------------------------------------------------
const ITEM_LOOKUPS = parseInt(process.env.PAYMENT_ITEM_LOOKUPS || '0', 10);

// ---------------------------------------------------------------------------
// Second bad release (2.1.0). Same shape of mistake as ITEM_LOOKUPS, but a
// DIFFERENT table and a different statement, so Coworker sees a new problem
// rather than a repeat of 2.0.3:
//
//   2.0.3  SELECT ... FROM services  WHERE service_id = ?     (flat, 50 rows)
//   2.1.0  SELECT ... FROM quotes JOIN customers ...          (join, 729 rows)
//
// `quotes` is untouched by 2.0.3, and the join makes db.statement obviously
// distinct in a trace even though both produce spans named "SELECT".
//
// Independent of ITEM_LOOKUPS: setting one does not affect the other, and both
// are off unless their env var is set.
// ---------------------------------------------------------------------------
const CUSTOMER_LOOKUPS = parseInt(process.env.PAYMENT_CUSTOMER_LOOKUPS || '0', 10);

/** Simulate the per-item lookups a naive implementation would do. */
async function lookupItemPricing(span) {
  // Items in a basket. Bounded so the query count stays in the intended range.
  const itemCount = 8 + Math.floor(Math.random() * 8);          // 8-15 items
  const perItem = Math.max(1, Math.min(20, ITEM_LOOKUPS));       // lookups each
  let queries = 0;

  for (let i = 0; i < itemCount; i++) {
    // One row, by primary key, from a 50-row table.
    const serviceId = 1 + Math.floor(Math.random() * 50);
    for (let j = 0; j < perItem; j++) {
      await pool.execute(
        'SELECT service_id, service_name, base_price FROM services WHERE service_id = ?',
        [serviceId]
      );
      queries++;
    }
  }

  // A few fixed lookups on top, as a real one would have.
  for (let k = 0; k < 6; k++) {
    await pool.execute(
      'SELECT customer_id, company_name FROM customers WHERE customer_id = ?',
      [1 + Math.floor(Math.random() * 50)]
    );
    queries++;
  }

  span.setAttributes({
    'app.payment.item_count': itemCount,
    'app.payment.pricing_queries': queries
  });
  return queries;
}

/**
 * Simulate resolving the owning customer for every basket item, one query at
 * a time. Each query is a primary-key lookup joined to customers on its
 * primary key, so it is sub-millisecond and the database is never at risk -
 * the damage is doing 80-150 of them sequentially per charge.
 */
async function lookupItemCustomer(span) {
  const itemCount = 8 + Math.floor(Math.random() * 8);           // 8-15 items
  const perItem = Math.max(1, Math.min(20, CUSTOMER_LOOKUPS));
  let queries = 0;

  for (let i = 0; i < itemCount; i++) {
    // quote_id range in the seed data is 31-759.
    const quoteId = 31 + Math.floor(Math.random() * 729);
    for (let j = 0; j < perItem; j++) {
      await pool.execute(
        'SELECT q.quote_id, q.quote_number, q.total_amount, c.company_name, c.email ' +
          'FROM quotes q JOIN customers c ON c.customer_id = q.customer_id ' +
          'WHERE q.quote_id = ?',
        [quoteId]
      );
      queries++;
    }
  }

  span.setAttributes({
    'app.payment.item_count': itemCount,
    'app.payment.customer_queries': queries
  });
  return queries;
}

/** Return random element from given array */
function random(arr) {
  const index = Math.floor(Math.random() * arr.length);
  return arr[index];
}

module.exports.charge = async request => {
  const span = tracer.startSpan('charge');

  await OpenFeature.setProviderAndWait(flagProvider);

  const numberVariant =  await OpenFeature.getClient().getNumberValue("paymentFailure", 0);

  if (numberVariant > 0) {
    // n% chance to fail with app.loyalty.level=gold
    if (Math.random() < numberVariant) {
      span.setAttributes({'app.loyalty.level': 'gold' });
      span.end();

      throw new Error('Payment request failed. Invalid token. app.loyalty.level=gold');
    }
  }

  const {
    creditCardNumber: number,
    creditCardExpirationYear: year,
    creditCardExpirationMonth: month
  } = request.creditCard;
  const currentMonth = new Date().getMonth() + 1;
  const currentYear = new Date().getFullYear();
  const lastFourDigits = number.substr(-4);
  const transactionId = uuidv4();

  const card = cardValidator(number);
  const { card_type: cardType, valid } = card.getCardDetails();

  const loyalty_level = random(LOYALTY_LEVEL);

  span.setAttributes({
    'app.payment.card_type': cardType,
    'app.payment.card_valid': valid,
    'app.loyalty.level': loyalty_level
  });

  if (!valid) {
    throw new Error('Credit card info is invalid.');
  }

  if (!['visa', 'mastercard'].includes(cardType)) {
    throw new Error(`Sorry, we cannot process ${cardType} credit cards. Only VISA or MasterCard is accepted.`);
  }

  if ((currentYear * 12 + currentMonth) > (year * 12 + month)) {
    throw new Error(`The credit card (ending ${lastFourDigits}) expired on ${month}/${year}.`);
  }

  // Check baggage for synthetic_request=true, and add charged attribute accordingly
  const baggage = propagation.getBaggage(context.active());
  let charged = true;
  if (baggage && baggage.getEntry('synthetic_request') && baggage.getEntry('synthetic_request').value === 'true') {
    span.setAttribute('app.payment.charged', false);
    charged = false;
  } else {
    span.setAttribute('app.payment.charged', true);
    charged = true;
  }

  const { units, nanos, currencyCode } = request.amount;

  // Check for database error injection via feature flag
  const dbErrorRate = await OpenFeature.getClient().getNumberValue("paymentDatabaseError", 0);

  if (dbErrorRate > 0 && Math.random() < dbErrorRate) {
    // Simulate realistic database errors
    const errorTypes = [
      { code: 'ECONNREFUSED', message: 'Database connection refused' },
      { code: 'ETIMEDOUT', message: 'Database connection timeout' },
      { code: 'ER_LOCK_WAIT_TIMEOUT', message: 'Lock wait timeout exceeded; try restarting transaction' },
      { code: 'ER_LOCK_DEADLOCK', message: 'Deadlock found when trying to get lock; try restarting transaction' }
    ];
    const error = errorTypes[Math.floor(Math.random() * errorTypes.length)];
    span.recordException(error);
    // Without this the charge span stays Unset and only the gRPC span above it
    // carries Error, which makes the innermost span dishonest about a failure.
    span.setStatus({ code: SpanStatusCode.ERROR, message: error.message });
    span.end();

    const dbError = new Error(`Database error: ${error.message}`);
    dbError.code = error.code;
    throw dbError;
  }

  // Store transaction in MySQL database
  try {
    if (ITEM_LOOKUPS > 0) {
      const queries = await lookupItemPricing(span);
      logger.info({ transactionId, queries }, 'Priced basket items individually.');
    }

    if (CUSTOMER_LOOKUPS > 0) {
      const queries = await lookupItemCustomer(span);
      logger.info({ transactionId, queries }, 'Resolved the owning customer for each basket item.');
    }

    // Convert gRPC Long types to numbers for MySQL
    const unitsValue = typeof units === 'object' && units.toNumber ? units.toNumber() : Number(units);
    const nanosValue = typeof nanos === 'object' && nanos.toNumber ? nanos.toNumber() : Number(nanos);

    // executeWithTimeout is pool.execute() unless PAYMENT_QUERY_TIMEOUT_MS is
    // set, so this is a no-op change until the failure scenario is switched on.
    await pool.executeWithTimeout(
      'INSERT INTO payment_transactions (transaction_id, card_type, last_four_digits, amount_units, amount_nanos, currency_code, loyalty_level, charged) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [transactionId, cardType, lastFourDigits, unitsValue, nanosValue, currencyCode, loyalty_level, charged]
    );
    logger.info({ transactionId, cardType, lastFourDigits, amount: { units, nanos, currencyCode }, loyalty_level }, 'Transaction complete and stored in database.');
  } catch (err) {
    logger.error({ err, transactionId }, 'Failed to store transaction in database');
    span.recordException(err);
    span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
    span.end();
    throw new Error(`Failed to store transaction: ${err.message}`);
  }

  transactionsCounter.add(1, { 'app.payment.currency': currencyCode });
  span.end();

  return { transactionId };
};
