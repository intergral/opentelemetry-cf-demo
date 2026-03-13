// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import { initializeFaro, getWebInstrumentations, type Faro } from '@grafana/faro-web-sdk';
import { TracingInstrumentation } from '@grafana/faro-web-tracing';

const DEFAULT_FARO_URL = 'http://localhost:12347/collect';
const DEFAULT_FARO_APP_NAME = 'otel-demo-frontend';
const DEFAULT_FARO_SAMPLE_RATE = 0.05;

let faro: Faro | undefined;

export const getFaro = (): Faro | undefined => faro;

const initFaro = (): Faro | undefined => {
  if (typeof window === 'undefined' || faro) return faro;

  const url = window.ENV?.FARO_COLLECTOR_URL || DEFAULT_FARO_URL;
  const appName = window.ENV?.FARO_APP_NAME || DEFAULT_FARO_APP_NAME;
  const parsedRate = parseFloat(window.ENV?.FARO_SAMPLE_RATE ?? '');
  const sampleRate = isNaN(parsedRate) ? DEFAULT_FARO_SAMPLE_RATE : parsedRate;

  faro = initializeFaro({
    url,
    app: {
      name: appName,
      environment: 'demo',
    },
    sessionTracking: {
      samplingRate: sampleRate,
    },
    instrumentations: [
      ...getWebInstrumentations({
        captureConsole: true,
      }),
      new TracingInstrumentation(),
    ],
  });

  return faro;
};

export default initFaro;