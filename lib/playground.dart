// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library playground;

import 'dart:async';
import 'dart:html' hide Document;

import 'package:logging/logging.dart';
import 'package:route_hierarchical/client.dart';

import 'completion.dart';
import 'context.dart';
import 'core/dependencies.dart';
import 'core/keys.dart';
import 'core/modules.dart';
import 'dart_pad.dart';
import 'dialogs.dart';
import 'documentation.dart';
import 'editing/editor.dart';
import 'elements/bind.dart';
import 'elements/elements.dart';
import 'modules/codemirror_module.dart';
import 'modules/dart_pad_module.dart';
import 'modules/dartservices_module.dart';
import 'playground_context.dart';
import 'services/_dartpadsupportservices.dart';
import 'services/common.dart';
import 'services/dartservices.dart';
import 'services/execution_iframe.dart';
import 'sharing/editor_doc_property.dart';
import 'sharing/gist_file_property.dart';
import 'sharing/gists.dart';
import 'sharing/gist_storage.dart';
import 'sharing/mutable_gist.dart';
import 'src/ga.dart';
import 'src/util.dart';

Playground get playground => _playground;

Playground _playground;

final Logger _logger = Logger('dartpad');

/// Controls whether we request compilation using dart2js or DDC.
const bool _useDDC = false;

void init() {
  _playground = Playground();
}

class Playground implements GistContainer, GistController {
  DivElement get _editpanel => querySelector('#editpanel');

  DivElement get _outputpanel => querySelector('#output');

  IFrameElement get _frame => querySelector('#frame');

  bool get _isCompletionActive => editor.completionActive;

  DivElement get _docPanel => querySelector('#documentation');

  DButton runButton;
  DButton formatButton;
  DOverlay overlay;
  DBusyLight busyLight;
  DBusyLight consoleBusyLight;
  Editor editor;
  PlaygroundContext _context;
  Future _analysisRequest;
  MutableGist editableGist = MutableGist(Gist());
  final _gistStorage = GistStorage();
  DContentEditable titleEditable;

  TabController sourceTabController;
  TabController outputTabController;
  SharingDialog sharingDialog;
  KeysDialog settings;

  // We store the last returned shared gist; it's used to update the url.
  Gist _overrideNextRouteGist;
  DocHandler docHandler;

  Playground() {
    sourceTabController = TabController();
    for (String name in ['dart', 'html', 'css']) {
      sourceTabController.registerTab(
          TabElement(querySelector('#${name}tab'), name: name, onSelect: () {
        Element issuesElement = querySelector('#issues');
        issuesElement.style.display = name == 'dart' ? 'block' : 'none';
        ga.sendEvent('edit', name);
        _context.switchTo(name);
      }));
    }

    overlay = DOverlay(querySelector('#frame-overlay'));

    sharingDialog = SharingDialog(this, this);

    DButton newButton = DButton(querySelector('#newbutton'));
    OkCancelDialog newDialog = OkCancelDialog(
        'Create New Pad', 'Discard changes to the current pad?', createNewGist,
        okText: 'Discard');
    newButton.onClick.listen((_) {
      newDialog.show();
    });

    DButton resetButton = DButton(querySelector('#resetbutton'));
    OkCancelDialog resetDialog = OkCancelDialog(
        'Reset Pad', 'Discard changes to the current pad?', _resetGists,
        okText: 'Discard', cancelText: 'Cancel');
    resetButton.onClick.listen((_) {
      resetDialog.show();
    });

    editableGist.onDirtyChanged.listen((val) {
      resetButton.disabled = !val;
    });

    DButton shareButton = DButton(querySelector('#sharebutton'));

    shareButton.onClick.listen((Event e) => window.open(
        'https://github.com/dart-lang/dart-pad/wiki/Sharing-Guide',
        '_sharing'));

    // Sharing is currently disabled pending establishing OAuth2 configurations with Github.
    // shareButton.onClick.listen((Event e) => _createSummary()
    //    .then((GistSummary summary) => sharingDialog.showWithSummary(summary)));

    formatButton = DButton(querySelector('#formatbutton'));
    formatButton.onClick.listen((Event e) => _format());

    runButton = DButton(querySelector('#runbutton'));
    runButton.onClick.listen((e) {
      _handleRun();

      // On a mobile device, focusing the editing area causes the keyboard to
      // pop up when the user hits the run button.
      if (!isMobile()) _context.focus();
    });

    // Listen for the keyboard button.
    querySelector('#keyboard-button').onClick.listen((_) => settings.show());

    busyLight = DBusyLight(querySelector('#dartbusy'));
    consoleBusyLight = DBusyLight(querySelector('#consolebusy'));

    // Update the title on changes.
    titleEditable = DContentEditable(querySelector('header .header-gist-name'));
    bind(titleEditable.onChanged, editableGist.property('description'));
    bind(editableGist.property('description'), titleEditable.textProperty);
    editableGist.onDirtyChanged.listen((val) {
      titleEditable.element.classes.toggle('dirty', val);
    });

    // If there was a change, and the gist is dirty, write the gist's contents
    // to storage.
    debounceStream(mutableGist.onChanged, Duration(milliseconds: 100))
        .listen((_) {
      if (mutableGist.dirty) {
        _gistStorage.setStoredGist(mutableGist.createGist());
      }
    });

    SelectElement select = querySelector('#samples');
    select.onChange.listen((_) => _handleSelectChanged(select));

    // Show the about box on title clicks.
    querySelector('div.header-title').onClick.listen((e) {
      e.preventDefault();
      _showAboutBox();
    });

    // Show the about box on version text clicks.
    querySelector('#dartpad_version').onClick.listen((e) {
      e.preventDefault();
      _showAboutBox();
    });

    _initModules().then((_) {
      _initPlayground();
    });
  }

  void _showAboutBox() {
    dartServices
        .version()
        .timeout(Duration(seconds: 2))
        .then((VersionResponse ver) {
      print('Dart SDK version ${ver.sdkVersion} (${ver.sdkVersionFull})');
      print('CodeMirror: ${CodeMirrorModule.version}');
      AboutDialog(ver.sdkVersionFull)..show();
    }).catchError((e) {
      AboutDialog()..show();
    });
  }

  void _resetGists() {
    _gistStorage.clearStoredGist();
    editableGist.reset();
    // Delay to give time for the model change event to propagate through
    // to the editor component (which is where `_performAnalysis()` pulls
    // the Dart source from).
    Timer.run(_performAnalysis);
    _clearOutput();
  }

  Future showHome(RouteEnterEvent event) async {
    // Don't auto-run if we're re-loading some unsaved edits; the gist might
    // have halting issues (#384).
    bool loadedFromSaved = false;
    Uri url = Uri.parse(window.location.toString());

    if (url.hasQuery &&
        url.queryParameters['id'] != null &&
        isLegalGistId(url.queryParameters['id'])) {
      _showGist(url.queryParameters['id']);
    } else if (url.hasQuery && url.queryParameters['export'] != null) {
      UuidContainer requestId = UuidContainer()
        ..uuid = url.queryParameters['export'];
      Future<PadSaveObject> exportPad =
          dartSupportServices.pullExportContent(requestId);
      await exportPad.then((pad) {
        Gist blankGist = createSampleDartGist();
        blankGist.getFile('main.dart').content = pad.dart;
        blankGist.getFile('index.html').content = pad.html;
        blankGist.getFile('styles.css').content = pad.css;
        editableGist.setBackingGist(blankGist);
      });
    } else if (url.hasQuery && url.queryParameters['source'] != null) {
      UuidContainer gistId = await dartSupportServices.retrieveGist(
          id: url.queryParameters['source']);
      Gist backing;

      try {
        backing = await gistLoader.loadGist(gistId.uuid);
      } catch (ex) {
        print(ex);
        backing = Gist();
      }

      editableGist.setBackingGist(backing);
      await router.go('gist', {'gist': backing.id});
    } else if (_gistStorage.hasStoredGist && _gistStorage.storedId == null) {
      loadedFromSaved = true;

      Gist blankGist = Gist();
      editableGist.setBackingGist(blankGist);

      Gist storedGist = _gistStorage.getStoredGist();
      editableGist.description = storedGist.description;
      for (GistFile file in storedGist.files) {
        editableGist.getGistFile(file.name).content = file.content;
      }
    } else {
      editableGist.setBackingGist(createSampleDartGist());
    }

    _clearOutput();
    // We delay this because of the latency in populating the editors from the
    // gist data.
    Timer.run(_autoSwitchSourceTab);

    // Analyze and run it.
    Timer.run(() {
      _performAnalysis().then((bool result) {
        // Only auto-run if the static analysis comes back clean.
        if (result && !loadedFromSaved) _handleRun();
        if (url.hasQuery && url.queryParameters['line'] != null) {
          _jumpToLine(int.parse(url.queryParameters['line']));
        }
      }).catchError((e) => null);
    });
  }

  void showGist(RouteEnterEvent event) {
    String gistId = event.parameters['gist'];

    _clearOutput();

    if (!isLegalGistId(gistId)) {
      showHome(event);
      return;
    }

    _showGist(gistId);
  }

  // GistContainer interface
  @override
  MutableGist get mutableGist => editableGist;

  @override
  void overrideNextRoute(Gist gist) {
    _overrideNextRouteGist = gist;
  }

  @override
  Future createNewGist() {
    _gistStorage.clearStoredGist();

    if (ga != null) ga.sendEvent('main', 'new');

    DToast.showMessage('New pad created');
    router.go('gist', {'gist': ''}, forceReload: true);

    return Future.value();
  }

  void _showGist(String gistId) {
    // Don't auto-run if we're re-loading some unsaved edits; the gist might
    // have halting issues (#384).
    bool loadedFromSaved = false;

    // When sharing, we have to pipe the returned (created) gist through the
    // routing library to update the url properly.
    if (_overrideNextRouteGist != null && _overrideNextRouteGist.id == gistId) {
      editableGist.setBackingGist(_overrideNextRouteGist);
      _overrideNextRouteGist = null;
      return;
    }

    _overrideNextRouteGist = null;

    gistLoader.loadGist(gistId).then((Gist gist) {
      editableGist.setBackingGist(gist);

      if (_gistStorage.hasStoredGist && _gistStorage.storedId == gistId) {
        loadedFromSaved = true;

        Gist storedGist = _gistStorage.getStoredGist();
        editableGist.description = storedGist.description;
        for (GistFile file in storedGist.files) {
          editableGist.getGistFile(file.name).content = file.content;
        }
      }

      _clearOutput();

      // We delay this because of the latency in populating the editors from the
      // gist data.
      Timer.run(_autoSwitchSourceTab);

      if (isWebContentShowing != gist.hasWebContent()) {
        if (gist.hasWebContent()) {
          showWebContent();
        } else {
          hideWebContent();
        }
      }

      // Analyze and run it.
      Timer.run(() {
        _performAnalysis().then((bool result) {
          // Only auto-run if the static analysis comes back clean.
          if (result && !loadedFromSaved) _handleRun();
        }).catchError((e) => null);
      });
    }).catchError((e) {
      String message = 'Error loading gist $gistId.';
      DToast.showMessage(message);
      _logger.severe('$message: $e');
    });
  }

  Future _initModules() {
    ModuleManager modules = ModuleManager();

    modules.register(DartPadModule());
    modules.register(DartServicesModule());
    modules.register(DartSupportServicesModule());
    modules.register(CodeMirrorModule());

    return modules.start();
  }

  void _initPlayground() {
    var disablePointerEvents = () {
      _frame.style.pointerEvents = 'none';
    };
    var enablePointerEvents = () {
      _frame.style.pointerEvents = 'inherit';
    };

    DSplitter editorSplitter = DSplitter(querySelector('#editor_split'),
        onDragStart: disablePointerEvents, onDragEnd: enablePointerEvents);
    editorSplitter.onPositionChanged.listen((pos) {
      state['editor_split'] = pos;
      editor.resize();
    });
    if (state['editor_split'] != null) {
      editorSplitter.position = state['editor_split'];
    }

    DSplitter outputSplitter = DSplitter(querySelector('#output_split'),
        onDragStart: disablePointerEvents, onDragEnd: enablePointerEvents);
    outputSplitter.onPositionChanged.listen((pos) {
      state['output_split'] = pos;
    });
    if (state['output_split'] != null) {
      outputSplitter.position = state['output_split'];
    }

    // Set up the iframe.
    deps[ExecutionService] = ExecutionServiceIFrame(_frame);
    executionService.onStdout.listen(_showOutput);
    executionService.onStderr.listen((m) => _showOutput(m, error: true));

    // Set up Google Analytics.
    deps[Analytics] = Analytics();

    // Set up the gist loader.
    deps[GistLoader] = GistLoader.defaultFilters();

    // Set up the editing area.
    editor = editorFactory.createFromElement(_editpanel);
    _editpanel.children.first.attributes['flex'] = '';
    editor.resize();

    keys.bind(['ctrl-s'], _handleSave, 'Save', hidden: true);
    keys.bind(['ctrl-enter'], _handleRun, 'Run');
    keys.bind(['f1'], () {
      ga.sendEvent('main', 'help');
      docHandler.generateDoc(_docPanel);
    }, 'Documentation');

    keys.bind(['alt-enter'], () {
      editor.showCompletions(onlyShowFixes: true);
    }, 'Quick fix');

    keys.bind(['ctrl-space', 'macctrl-space'], () {
      editor.showCompletions();
    }, 'Completion');

    keys.bind(['shift-ctrl-/', 'shift-macctrl-/'], () {
      if (settings.isShowing) {
        settings.hide();
      } else {
        settings.show();
      }
    }, 'Keyboard Shortcuts');

    settings = KeysDialog(keys.inverseBindings);

    document.onKeyUp.listen((e) {
      if (editor.completionActive ||
          DocHandler.cursorKeys.contains(e.keyCode)) {
        docHandler.generateDoc(_docPanel);
      }
      _handleAutoCompletion(e);
    });

    outputTabController = TabController()
      ..registerTab(
          TabElement(querySelector('#resulttab'), name: 'result', onSelect: () {
        ga.sendEvent('view', 'result');
        querySelector('#frame').style.visibility = 'visible';
        querySelector('#output').style.visibility = 'hidden';
      }))
      ..registerTab(TabElement(querySelector('#consoletab'), name: 'console',
          onSelect: () {
        ga.sendEvent('view', 'console');
        querySelector('#output').style.visibility = 'visible';
        querySelector('#frame').style.visibility = 'hidden';
      }));

    _context = PlaygroundContext(editor);
    _context.onModeChange.listen((_) {
      formatButton.disabled = _context.activeMode != 'dart';
    });
    deps[Context] = _context;

    editorFactory.registerCompleter(
        'dart', DartCompleter(dartServices, _context.dartDocument));

    _context.onHtmlDirty.listen((_) => busyLight.on());
    _context.onHtmlReconcile.listen((_) {
      executionService.replaceHtml(_context.htmlSource);
      busyLight.reset();
    });

    _context.onCssDirty.listen((_) => busyLight.on());
    _context.onCssReconcile.listen((_) {
      executionService.replaceCss(_context.cssSource);
      busyLight.reset();
    });

    _context.onDartDirty.listen((_) => busyLight.on());
    _context.onDartReconcile.listen((_) => _performAnalysis());

    // Listen for changes that would effect the documentation panel.
    editor.onMouseDown.listen((e) {
      // Delay to give codemirror time to process the mouse event.
      Timer.run(() {
        if (!_context.cursorPositionIsWhitespace()) {
          docHandler.generateDoc(_docPanel);
        }
      });
    });
    context.onModeChange.listen((_) => docHandler.generateDoc(_docPanel));

    // Listen for clicks on the 'Show web content' checkbox.
    showWebContentInputElement.onClick.listen((MouseEvent event) {
      event.preventDefault();

      // Delay a bit as it looks like we can't programmatically change the value
      // of a checkbox in an event handler.
      Timer(const Duration(milliseconds: 100), () {
        final bool isChecked = showWebContentInputElement.checked;

        if (isChecked) {
          if (_context.hasWebContent()) {
            final OkCancelDialog dialog = OkCancelDialog(
              'Hide web content',
              'Discard the contents of the HTML and CSS tabs?',
              () {
                _context.htmlSource = '';
                _context.cssSource = '';
                hideWebContent();
              },
              okText: 'Discard',
            );
            dialog.show();
          } else {
            hideWebContent();
          }
        } else {
          showWebContent();
        }
      });
    });

    // Bind the editable files to the gist.
    Property htmlFile =
        GistFileProperty(editableGist.getGistFile('index.html'));
    Property htmlDoc = EditorDocumentProperty(_context.htmlDocument, 'html');
    bind(htmlDoc, htmlFile);
    bind(htmlFile, htmlDoc);

    Property cssFile = GistFileProperty(editableGist.getGistFile('styles.css'));
    Property cssDoc = EditorDocumentProperty(_context.cssDocument, 'css');
    bind(cssDoc, cssFile);
    bind(cssFile, cssDoc);

    Property dartFile = GistFileProperty(editableGist.getGistFile('main.dart'));
    Property dartDoc = EditorDocumentProperty(_context.dartDocument, 'dart');
    bind(dartDoc, dartFile);
    bind(dartFile, dartDoc);

    // Set up the router.
    deps[Router] = Router();
    router.root.addRoute(name: 'home', defaultRoute: true, enter: showHome);
    router.root.addRoute(name: 'gist', path: '/:gist', enter: showGist);
    router.listen();

    docHandler = DocHandler(editor, _context);

    dartServices.version().then((VersionResponse version) {
      // "Based on Dart SDK 1.25.0-dev"
      String versionText = 'Based on Dart SDK ${version.sdkVersionFull}';
      querySelector('#dartpad_version').text = versionText;
    }).catchError((e) => null);

    _finishedInit();
  }

  void _finishedInit() {
    // Clear the splash.
    DSplash splash = DSplash(querySelector('div.splash'));
    splash.hide();
  }

  final RegExp cssSymbolRegexp = RegExp(r'[A-Z]');

  void _handleAutoCompletion(KeyboardEvent e) {
    if (context.focusedEditor == 'dart' && editor.hasFocus) {
      if (e.keyCode == KeyCode.PERIOD) {
        editor.showCompletions(autoInvoked: true);
      }
    }

    if (!_isCompletionActive && editor.hasFocus) {
      if (context.focusedEditor == 'html') {
        if (printKeyEvent(e) == 'shift-,') {
          editor.showCompletions(autoInvoked: true);
        }
      } else if (context.focusedEditor == 'css') {
        if (cssSymbolRegexp.hasMatch(String.fromCharCode(e.keyCode))) {
          editor.showCompletions(autoInvoked: true);
        }
      }
    }
  }

  void _handleRun() async {
    ga.sendEvent('main', 'run');
    runButton.disabled = true;
    overlay.visible = true;

    Stopwatch compilationTimer = Stopwatch()..start();

    final CompileRequest compileRequest = CompileRequest()
      ..source = context.dartSource;

    try {
      if (_useDDC) {
        final CompileDDCResponse response = await dartServices
            .compileDDC(compileRequest)
            .timeout(longServiceCallTimeout);

        ga.sendTiming(
          'action-perf',
          'compilation-e2e',
          compilationTimer.elapsedMilliseconds,
        );

        _autoSwitchOutputTab();
        _clearOutput();

        return executionService.execute(
          _context.htmlSource,
          _context.cssSource,
          response.result,
          modulesBaseUrl: response.modulesBaseUrl,
        );
      } else {
        final CompileResponse response = await dartServices
            .compile(compileRequest)
            .timeout(longServiceCallTimeout);

        ga.sendTiming(
          'action-perf',
          'compilation-e2e',
          compilationTimer.elapsedMilliseconds,
        );

        _autoSwitchOutputTab();
        _clearOutput();

        return executionService.execute(
          _context.htmlSource,
          _context.cssSource,
          response.result,
        );
      }
    } catch (e) {
      ga.sendException('${e.runtimeType}');
      final message = (e is DetailedApiRequestError) ? e.message : '$e';
      DToast.showMessage('Error compiling to JavaScript');
      _showOutput('Error compiling to JavaScript:\n$message', error: true);
    } finally {
      runButton.disabled = false;
      overlay.visible = false;
    }
  }

  /// Switch to the Dart / Html / Css tab depending on the sample type.
  void _autoSwitchSourceTab() {
    String htmlSrc = _context.htmlSource.trim();
    String dartSrc = _context.dartSource.trim();

    if (htmlSrc.isEmpty && dartSrc.isNotEmpty) {
      sourceTabController.selectTab('dart');
    }
  }

  /// Switch to the console or html results tab depending on whether the sample
  /// has html content or not.
  void _autoSwitchOutputTab() {
    if (!isWebContentShowing) {
      return;
    }

    String htmlSrc = _context.htmlSource.trim();
    String dartSrc = _context.dartSource.trim();

    final List<String> webImports = [
      "import 'dart:html'",
      'import "dart:html"',
      //"import 'package:flutter_web",
      //'import "package:flutter_web',
    ];

    if (htmlSrc.isNotEmpty) {
      outputTabController.selectTab('result');
    } else if (webImports.any((String import) => dartSrc.contains(import))) {
      outputTabController.selectTab('result');
    } else {
      outputTabController.selectTab('console');
    }
  }

  /* Future<GistSummary> _createSummary() {
    return dartSupportServices.getUnusedMappingId().then((UuidContainer id) {
      _mappingId = id.uuid;
      SourcesRequest input = new SourcesRequest()
        ..sources = {
          'dart': _context.dartSource,
          'css': _context.cssSource,
          'html': _context.htmlSource
        };
      return dartServices.summarize(input);
    }).then((SummaryText summary) {
      return new GistSummary(summary.text,
          'Find this at [dartpad.dartlang.org/?source=${_mappingId}](https://dartpad.dartlang.org/?source=${_mappingId}).');
    }).catchError((e) {
      _logger.severe(e);
    });
  } */

  /// Perform static analysis of the source code. Return whether the code
  /// analyzed cleanly (had no errors or warnings).
  Future<bool> _performAnalysis() {
    SourceRequest input = SourceRequest()..source = _context.dartSource;

    Lines lines = Lines(input.source);

    Future<AnalysisResults> request =
        dartServices.analyze(input).timeout(serviceCallTimeout);
    _analysisRequest = request;

    return request.then((AnalysisResults result) {
      // Discard if we requested another analysis.
      if (_analysisRequest != request) return false;

      // Discard if the document has been mutated since we requested analysis.
      if (input.source != _context.dartSource) return false;

      busyLight.reset();

      _displayIssues(result.issues);

      _context.dartDocument
          .setAnnotations(result.issues.map((AnalysisIssue issue) {
        int startLine = lines.getLineForOffset(issue.charStart);
        int endLine =
            lines.getLineForOffset(issue.charStart + issue.charLength);

        Position start = Position(
            startLine, issue.charStart - lines.offsetForLine(startLine));
        Position end = Position(
            endLine,
            issue.charStart +
                issue.charLength -
                lines.offsetForLine(startLine));

        return Annotation(issue.kind, issue.message, issue.line,
            start: start, end: end);
      }).toList());

      bool hasErrors = result.issues.any((issue) => issue.kind == 'error');
      bool hasWarnings = result.issues.any((issue) => issue.kind == 'warning');

      _updateRunButton(hasErrors: hasErrors, hasWarnings: hasWarnings);

      return hasErrors == false && hasWarnings == false;
    }).catchError((e) {
      _context.dartDocument.setAnnotations([]);
      busyLight.reset();
      _updateRunButton();
      _logger.severe(e);
    });
  }

  Future _format() {
    String originalSource = _context.dartSource;
    SourceRequest input = SourceRequest()..source = originalSource;
    formatButton.disabled = true;

    Future<FormatResponse> request =
        dartServices.format(input).timeout(serviceCallTimeout);
    return request.then((FormatResponse result) {
      busyLight.reset();
      formatButton.disabled = false;

      if (result.newString == null || result.newString.isEmpty) {
        _logger.fine('Format returned null/empty result');
        return;
      }

      if (originalSource != result.newString) {
        editor.document.updateValue(result.newString);
        DToast.showMessage('Format successful.');
      } else {
        DToast.showMessage('No formatting changes.');
      }
    }).catchError((e) {
      busyLight.reset();
      formatButton.disabled = false;
      _logger.severe(e);
    });
  }

  void _handleSave() => ga.sendEvent('main', 'save');

  void _clearOutput() {
    _outputpanel.text = '';
  }

  InputElement get showWebContentInputElement =>
      querySelector('#show-web-content');

  bool get isWebContentShowing =>
      querySelector('#htmltab').style.visibility != 'hidden';

  void showWebContent() {
    showWebContentInputElement.checked = true;

    querySelector('#htmltab').style.visibility = 'initial';
    querySelector('#csstab').style.visibility = 'initial';

    querySelector('#resulttab').style.visibility = 'initial';
  }

  void hideWebContent() {
    showWebContentInputElement.checked = false;

    // Switch to dart tab, and the console output tab.
    sourceTabController.selectTab('dart');
    outputTabController.selectTab('console');

    querySelector('#htmltab').style.visibility = 'hidden';
    querySelector('#csstab').style.visibility = 'hidden';

    querySelector('#resulttab').style.visibility = 'hidden';
  }

  final _bufferedOutput = <SpanElement>[];
  final _outputDuration = Duration(milliseconds: 32);

  void _showOutput(String message, {bool error = false}) {
    consoleBusyLight.flash();

    SpanElement span = SpanElement()..text = '$message\n';
    span.classes.add(error ? 'error-output' : 'normal');

    // Buffer the console output so that heavy writing to stdout does not starve
    // the DOM thread.
    _bufferedOutput.add(span);

    if (_bufferedOutput.length == 1) {
      Timer(_outputDuration, () {
        _outputpanel.children.addAll(_bufferedOutput);
        _outputpanel.children.last.scrollIntoView(ScrollAlignment.BOTTOM);
        _bufferedOutput.clear();
      });
    }
  }

  void _handleSelectChanged(SelectElement select) {
    String value = select.value;

    if (isLegalGistId(value)) {
      router.go('gist', {'gist': value});
    }

    select.value = '0';
  }

  void _displayIssues(List<AnalysisIssue> issues) {
    Element issuesElement = querySelector('#issues');

    // Detect when hiding; don't remove the content until hidden.
    bool isHiding = issuesElement.children.isNotEmpty && issues.isEmpty;

    if (isHiding) {
      issuesElement.classes.toggle('showing', issues.isNotEmpty);

      StreamSubscription sub;
      sub = issuesElement.onTransitionEnd.listen((_) {
        issuesElement.children.clear();
        sub.cancel();
      });
    } else {
      issuesElement.children.clear();

      issues.sort((a, b) => a.charStart - b.charStart);

      // Create an item for each issue.
      for (AnalysisIssue issue in issues) {
        DivElement e = DivElement();
        e.classes.add('issue');
        e.attributes['layout'] = '';
        e.attributes['horizontal'] = '';
        issuesElement.children.add(e);
        e.onClick.listen((_) {
          _jumpTo(issue.line, issue.charStart, issue.charLength, focus: true);
        });

        SpanElement typeSpan = SpanElement();
        typeSpan.classes.addAll([issue.kind, 'issuelabel']);
        typeSpan.text = issue.kind;
        e.children.add(typeSpan);

        SpanElement messageSpan = SpanElement();
        messageSpan.classes.add('message');
        messageSpan.attributes['flex'] = '';
        messageSpan.text = issue.message;
        e.children.add(messageSpan);
        if (issue.hasFixes) {
          e.classes.add('hasFix');
          e.onClick.listen((e) {
            // This is a bit of a hack to make sure quick fixes popup is only
            // shown if the wrench is clicked, and not if the text or label is
            // clicked.
            if ((e.target as Element).className == 'issue hasFix') {
              // codemiror only shows completions if there is no selected text
              _jumpTo(issue.line, issue.charStart, 0, focus: true);
              editor.showCompletions(onlyShowFixes: true);
            }
          });
        }
      }

      issuesElement.classes.toggle('showing', issues.isNotEmpty);
    }
  }

  void _updateRunButton({bool hasErrors = false, bool hasWarnings = false}) {
    const alertSVGIcon =
        'M5,3H19A2,2 0 0,1 21,5V19A2,2 0 0,1 19,21H5A2,2 0 0,1 3,19V5A2,2 0 0,'
        '1 5,3M13,13V7H11V13H13M13,17V15H11V17H13Z';

    var path = runButton.element.querySelector('path');
    path.attributes['d'] =
        (hasErrors || hasWarnings) ? alertSVGIcon : 'M8 5v14l11-7z';

    path.parent.classes.toggle('error', hasErrors);
    path.parent.classes.toggle('warning', hasWarnings && !hasErrors);
  }

  void _jumpTo(int line, int charStart, int charLength, {bool focus = false}) {
    Document doc = editor.document;

    doc.select(
        doc.posFromIndex(charStart), doc.posFromIndex(charStart + charLength));

    if (focus) editor.focus();
  }

  void _jumpToLine(int line) {
    Document doc = editor.document;
    doc.select(Position(line, 0), Position(line, 0));
    editor.focus();
  }
}
