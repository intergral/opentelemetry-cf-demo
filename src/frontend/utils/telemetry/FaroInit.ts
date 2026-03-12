// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import { initializeFaro, getWebInstrumentations, type Faro } from '@grafana/faro-web-sdk';

let faro: Faro | undefined;

export const getFaro = (): Faro | undefined => faro;

const initFaro = (): Faro | undefined => {
  if (typeof window === 'undefined' || faro) return faro;

  faro = initializeFaro({
    url: 'https://alloy.demo.streamhippo.io/collect',
    app: {
      name: 'otel-demo-frontend',
      environment: 'demo',
    },
    instrumentations: [
      ...getWebInstrumentations({
        captureConsole: true,
      }),
    ],
  });

  return faro;
};

export default initFaro;