// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

import { Component, ErrorInfo, ReactNode } from 'react';
import { getFaro } from '../../utils/telemetry/FaroInit';

interface Props {
  children: ReactNode;
}

interface State {
  hasError: boolean;
}

class FaroErrorBoundary extends Component<Props, State> {
  state: State = { hasError: false };

  static getDerivedStateFromError(): State {
    return { hasError: true };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    getFaro()?.api.pushError(error, {
      context: { componentStack: info.componentStack ?? '' },
    });
  }

  render() {
    if (this.state.hasError) {
      return <h2>Something went wrong.</h2>;
    }
    return this.props.children;
  }
}

export default FaroErrorBoundary;