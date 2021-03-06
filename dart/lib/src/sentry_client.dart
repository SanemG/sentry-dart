import 'dart:async';
import 'dart:math';

import 'protocol.dart';
import 'scope.dart';
import 'sentry_exception_factory.dart';
import 'sentry_options.dart';
import 'sentry_stack_trace_factory.dart';
import 'transport/http_transport.dart';
import 'transport/noop_transport.dart';
import 'version.dart';

/// Logs crash reports and events to the Sentry.io service.
class SentryClient {
  final SentryOptions _options;

  final Random _random;

  static final _sentryId = Future.value(SentryId.empty());

  SentryExceptionFactory _exceptionFactory;

  SentryStackTraceFactory _stackTraceFactory;

  /// Instantiates a client using [SentryOptions]
  factory SentryClient(SentryOptions options) {
    if (options == null) {
      throw ArgumentError('SentryOptions is required.');
    }

    if (options.transport is NoOpTransport) {
      options.transport = HttpTransport(options);
    }

    return SentryClient._(options);
  }

  /// Instantiates a client using [SentryOptions]
  SentryClient._(this._options)
      : _random = _options.sampleRate == null ? null : Random() {
    _stackTraceFactory = SentryStackTraceFactory(_options);
    _exceptionFactory = SentryExceptionFactory(
      options: _options,
      stacktraceFactory: _stackTraceFactory,
    );
  }

  /// Reports an [event] to Sentry.io.
  Future<SentryId> captureEvent(
    SentryEvent event, {
    Scope scope,
    dynamic stackTrace,
    dynamic hint,
  }) async {
    event = _processEvent(event, eventProcessors: _options.eventProcessors);

    // dropped by sampling or event processors
    if (event == null) {
      return _sentryId;
    }

    if (scope != null) {
      event = scope.applyToEvent(event, hint);
    } else {
      _options.logger(SentryLevel.debug, 'No scope is defined');
    }

    // dropped by scope event processors
    if (event == null) {
      return _sentryId;
    }

    event = _prepareEvent(event, stackTrace: stackTrace);

    if (_options.beforeSend != null) {
      try {
        event = _options.beforeSend(event, hint);
      } catch (err) {
        _options.logger(
          SentryLevel.error,
          'The BeforeSend callback threw an exception',
        );
      }
      if (event == null) {
        _options.logger(SentryLevel.debug, 'Event was dropped by a processor');
        return _sentryId;
      }
    }

    return _options.transport.send(event);
  }

  SentryEvent _prepareEvent(SentryEvent event, {dynamic stackTrace}) {
    event = event.copyWith(
      serverName: event.serverName ?? _options.serverName,
      dist: event.dist ?? _options.dist,
      environment:
          event.environment ?? _options.environment ?? defaultEnvironment,
      release: event.release ?? _options.release,
      sdk: event.sdk ?? _options.sdk,
      platform: event.platform ?? sdkPlatform,
    );

    if (event.exception != null) return event;

    if (event.throwable != null) {
      final sentryException = _exceptionFactory
          .getSentryException(event.throwable, stackTrace: stackTrace);

      return event.copyWith(exception: sentryException);
    }

    if (stackTrace != null || _options.attachStackTrace) {
      stackTrace ??= StackTrace.current;
      final frames = _stackTraceFactory.getStackFrames(stackTrace);

      if (frames != null && frames.isNotEmpty) {
        event = event.copyWith(stackTrace: SentryStackTrace(frames: frames));
      }
    }

    return event;
  }

  /// Reports the [throwable] and optionally its [stackTrace] to Sentry.io.
  Future<SentryId> captureException(
    dynamic throwable, {
    dynamic stackTrace,
    Scope scope,
    dynamic hint,
  }) {
    final event = SentryEvent(
      throwable: throwable,
      timestamp: _options.clock(),
    );

    return captureEvent(
      event,
      stackTrace: stackTrace,
      scope: scope,
      hint: hint,
    );
  }

  /// Reports the [template]
  Future<SentryId> captureMessage(
    String formatted, {
    SentryLevel level = SentryLevel.info,
    String template,
    List<dynamic> params,
    Scope scope,
    dynamic hint,
  }) {
    final event = SentryEvent(
      message: Message(formatted, template: template, params: params),
      level: level,
      timestamp: _options.clock(),
    );

    return captureEvent(event, scope: scope, hint: hint);
  }

  void close() => _options.httpClient?.close();

  SentryEvent _processEvent(
    SentryEvent event, {
    dynamic hint,
    List<EventProcessor> eventProcessors,
  }) {
    if (_sampleRate()) {
      _options.logger(
        SentryLevel.debug,
        'Event ${event.eventId.toString()} was dropped due to sampling decision.',
      );
      return null;
    }

    for (final processor in eventProcessors) {
      try {
        event = processor(event, hint);
      } catch (err) {
        _options.logger(
          SentryLevel.error,
          'An exception occurred while processing event by a processor : $err',
        );
      }
      if (event == null) {
        _options.logger(SentryLevel.debug, 'Event was dropped by a processor');
        break;
      }
    }
    return event;
  }

  bool _sampleRate() {
    if (_options.sampleRate != null && _random != null) {
      return (_options.sampleRate < _random.nextDouble());
    }
    return false;
  }
}
