<cfscript>

  dur = randRange(0,75,'SHA1PRNG')+100;
  sleep(dur);

  // 5% chance to run a deliberately slow query (5-8 seconds)
  slowQueryChance = randRange(1, 100, 'SHA1PRNG');
  
  if (slowQueryChance <= 5) {
    // Deliberately slow JDBC query using computationally expensive operations
    // This simulates real-world performance issues like bad indexing, complex calculations
    
    // SAFE SLOW QUERY - deliberately slow, but its cost does NOT grow with the
    // table.
    //
    // The original cross-joined `quotes` three times with a trailing LIMIT 10.
    // That LIMIT bounds the OUTPUT, not the work: the ORDER BY forces MySQL to
    // materialise every combination first, so cost was O(rows^3). At 281 rows
    // that was ~26 minutes and 3.5 billion rows examined, and it got 8x worse
    // every time the table doubled.
    //
    // Now each arm of the cross join is a derived table capped at
    // SLOW_QUERY_ROWS, so the work is a fixed SLOW_QUERY_ROWS^3 however large
    // `quotes` grows. Also:
    //   * no date() wrapper, so the quote_date index is usable
    //   * MAX_EXECUTION_TIME means MySQL kills the query itself - it can never
    //     outlive the Lucee request and strand an orphaned query
    //   * no memory_hog_field and only 10 short rows returned, so the JDBC
    //     driver has almost nothing to buffer into Lucee's heap
    // 150^3 = 3,375,000 combinations, measured at ~3.4s. Fixed: the derived
    // tables below cap each arm at slowRows regardless of how large `quotes`
    // grows, so this number - not the table - sets the cost. Re-measure if you
    // change it; the relationship is cubic.
    slowRows = 150;
    slowCapMs = 10000;      // MySQL-side ceiling, far below Lucee's 300s

    slowQuery = queryExecute("
      SELECT /*+ MAX_EXECUTION_TIME(#slowCapMs#) */
        q1.quote_id, q1.quote_number, CAST(q1.quote_date AS CHAR) as quote_date,
        q1.status, q1.total_amount,
        q2.quote_number as q2_number,
        q3.quote_number as q3_number,
        c1.company_name, c2.company_name as c2_company,
        (SELECT COUNT(*) FROM quote_items qi2 WHERE qi2.quote_id = q1.quote_id) as items_q1,
        (SELECT COUNT(*) FROM quote_items qi3 WHERE qi3.quote_id = q2.quote_id) as items_q2,
        (SELECT AVG(s2.base_price) FROM services s2) as avg_service_price,
        SQRT(q1.quote_id) * POWER(q2.quote_id % 97, 2) + SQRT(q3.quote_id + 1) as math_delay,
        LENGTH(CONCAT(q1.quote_number, q2.quote_number, q3.quote_number)) as total_length
      FROM
        (SELECT quote_id, quote_number, quote_date, status, total_amount, customer_id
           FROM quotes
          WHERE quote_date >= DATE_SUB(CURDATE(), INTERVAL 730 DAY)
          ORDER BY quote_id DESC LIMIT #slowRows#) q1
      CROSS JOIN
        (SELECT quote_id, quote_number, customer_id
           FROM quotes
          WHERE quote_date >= DATE_SUB(CURDATE(), INTERVAL 730 DAY)
          ORDER BY quote_id DESC LIMIT #slowRows#) q2
      CROSS JOIN
        (SELECT quote_id, quote_number
           FROM quotes
          WHERE quote_date >= DATE_SUB(CURDATE(), INTERVAL 730 DAY)
          ORDER BY quote_id DESC LIMIT #slowRows#) q3
      JOIN customers c1 ON q1.customer_id = c1.customer_id
      JOIN customers c2 ON q2.customer_id = c2.customer_id
      WHERE q1.quote_id <> q2.quote_id
        AND q2.quote_id <> q3.quote_id
        AND q1.quote_id <> q3.quote_id
      ORDER BY math_delay DESC, total_length DESC
      LIMIT 10
    ", {}, {datasource: "mysql"});
    
    writeLog(
      text="Executed computationally expensive slow query",
      type="information",
      application="yes",
      file="quote_cleanup"
    );
  } else {
    // Normal fast path (95% of calls). Bounded the same way as the slow path:
    // this was quotes CROSS JOIN quotes with a trailing LIMIT 25, so it was
    // O(rows^2) and grew with the table on EVERY call - 1.2 million
    // combinations at 1,095 rows. Now both arms are capped, the DATE()
    // wrappers are gone so the quote_date index is usable, and the UUID()
    // calls and memory_hog_field are dropped so there is little to buffer.
    fastRows = 40;        // 40 x 40 = 1,600 combinations, fixed
    fastCapMs = 3000;

    slowQuery = queryExecute("
      SELECT /*+ MAX_EXECUTION_TIME(#fastCapMs#) */
        q1.quote_id, q1.quote_number, CAST(q1.quote_date AS CHAR) as quote_date,
        q1.status, q1.total_amount,
        q2.quote_id as q2_id, q2.quote_number as q2_number, q2.total_amount as q2_total,
        c1.company_name, c1.contact_name, c1.email,
        c2.company_name as c2_company, c2.contact_name as c2_contact,
        UPPER(c1.company_name) as case_combo,
        LENGTH(CONCAT(q1.quote_number, q2.quote_number)) as total_length,
        SUBSTR(CONCAT(c1.company_name, c2.company_name), 1, 50) as company_combo
      FROM
        (SELECT quote_id, quote_number, quote_date, status, total_amount, customer_id
           FROM quotes
          WHERE quote_date >= DATE_SUB(CURDATE(), INTERVAL 365 DAY)
          ORDER BY quote_id DESC LIMIT #fastRows#) q1
      CROSS JOIN
        (SELECT quote_id, quote_number, total_amount, customer_id
           FROM quotes
          WHERE quote_date >= DATE_SUB(CURDATE(), INTERVAL 365 DAY)
          ORDER BY quote_id DESC LIMIT #fastRows#) q2
      JOIN customers c1 ON q1.customer_id = c1.customer_id
      JOIN customers c2 ON q2.customer_id = c2.customer_id
      WHERE q1.quote_id != q2.quote_id
      ORDER BY q1.quote_id DESC, q2.quote_id DESC
      LIMIT 25
    ", {}, {datasource: "mysql"});
  }

  // Summarise the result. Both queries now return at most 25 short rows and no
  // memory_hog_field or computed_hash columns, so there is nothing large to
  // accumulate - which is the point. The old version built an array from
  // columns deliberately designed to be big, on top of a result set that grew
  // with the table, and that is what exhausted quote's heap on 2026-11-09.
  largeDataArray = [];
  for (row = 1; row <= min(slowQuery.recordCount, 25); row++) {
    arrayAppend(largeDataArray, {
      "quote_number": slowQuery.quote_number[row],
      "company": slowQuery.company_name[row],
      "processed_at": now(),
      "row_number": row
    });
  }

  // Get old quotes to potentially remove
  oldQuotesQuery = queryExecute("
    SELECT quote_id, quote_number, CAST(quote_date AS CHAR) as quote_date, status, total_amount
    FROM quotes 
    WHERE quote_date < DATE_SUB(CURDATE(), INTERVAL 90 DAY)   -- no date(): keeps the index usable
    AND status IN ('draft', 'rejected', 'expired')
    ORDER BY quote_id ASC
    LIMIT 10
  ", {}, {datasource: "mysql"});

  deletedCount = 0;
  
  // Process each old quote
  for (i = 1; i <= oldQuotesQuery.recordCount; i++) {
    quoteId = oldQuotesQuery.quote_id[i];
    quoteStatus = oldQuotesQuery.status[i];
    
    // Create error condition based on duration
    if (dur > 150 && i == 1) {
      // Simulate error by trying to delete a quote that doesn't exist
      throw(type="DatabaseException", message="Cannot delete quote " & (quoteId + 99999) & " - foreign key constraint violation");
    }
    
    try {
      // Delete quote items first (foreign key dependency)
      queryExecute("
        DELETE FROM quote_items WHERE quote_id = :quoteId
      ", {
        quoteId: {value: quoteId, cfsqltype: "cf_sql_integer"}
      }, {datasource: "mysql"});
      
      // Then delete the quote
      deleteResult = queryExecute("
        DELETE FROM quotes WHERE quote_id = :quoteId
      ", {
        quoteId: {value: quoteId, cfsqltype: "cf_sql_integer"}
      }, {datasource: "mysql"});
      
      deletedCount++;
      
      // Log successful deletion
      writeLog(
        text="Deleted old quote: " & oldQuotesQuery.quote_number[i] & " (ID: " & quoteId & ")",
        type="information",
        application="yes",
        file="quote_cleanup"
      );
      
    } catch (any e) {
      // Log deletion errors
      writeLog(
        text="Error deleting quote " & quoteId & ": " & e.message,
        type="error",
        application="yes",
        file="quote_cleanup"
      );
      
      // Re-throw if it's our deliberate error
      if (findNoCase("foreign key constraint", e.message)) {
        throw(e);
      }
    }
  }

  // Return cleanup summary
  cleanupSummary = {
    "quotes_found": oldQuotesQuery.recordCount,
    "quotes_deleted": deletedCount,
    "cleanup_date": dateTimeFormat(now(), "yyyy-mm-dd HH:nn:ss")
  };
  
  writeOutput(serializeJSON(cleanupSummary));

</cfscript>
