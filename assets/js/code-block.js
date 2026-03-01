(function () {
  "use strict";

  var PARSERS = Object.create(null);

  PARSERS.python = {
    whitespace: /\s+/,
    comment: /#+[^\r\n]*/,
    string: /"""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\r\n])*"|'(?:\\.|[^'\r\n])*'/,
    keyword: /\b(?:False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b/,
    type: /\b(?:int|float|str|bool|list|dict|tuple|set|bytes|bytearray|memoryview|range|frozenset|complex|object|type)\b/,
    constant: /\b(?:True|False|None)\b/,
    function: /\b[A-Za-z_]\w*(?=\s*\()/,
    number: /0[xXoObB][\dA-Fa-f_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?/,
    operator: /[+\-*\/%=<>!&|^~@]+|:(?!=)/,
    punctuation: /[()[\]{},;:.]/,
    variable: /\b[A-Za-z_]\w*\b/,
    other: /\S/
  };

  PARSERS.javascript = {
    whitespace: /\s+/,
    comment: /\/\/[^\r\n]*|\/\*[\s\S]*?\*\//,
    string: /`(?:\\[\s\S]|[^`])*`|"(?:\\.|[^"\r\n])*"|'(?:\\.|[^'\r\n])*'/,
    keyword: /\b(?:async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|export|extends|finally|for|from|function|if|import|in|instanceof|let|new|of|return|static|super|switch|this|throw|try|typeof|var|void|while|with|yield)\b/,
    type: /\b(?:Array|Boolean|Date|Error|Function|Map|Number|Object|Promise|Proxy|RegExp|Set|String|Symbol|WeakMap|WeakSet)\b/,
    constant: /\b(?:true|false|null|undefined|NaN|Infinity)\b/,
    function: /\b[A-Za-z_$]\w*(?=\s*\()/,
    number: /0[xXoObB][\dA-Fa-f_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?/,
    operator: /[+\-*\/%=<>!&|^~?]+|\.{3}/,
    punctuation: /[()[\]{},;:.]/,
    variable: /\b[A-Za-z_$]\w*\b/,
    other: /\S/
  };

  PARSERS.html = {
    whitespace: /\s+/,
    comment: /<!--[\s\S]*?-->/,
    string: /"[^"]*"|'[^']*'/,
    keyword: /\b(?:DOCTYPE|html|head|body|div|span|p|a|ul|ol|li|h[1-6]|table|tr|td|th|form|input|button|select|textarea|label|img|link|meta|script|style|section|article|nav|header|footer|main|aside|figure|figcaption|details|summary|template|slot)\b/,
    type: /\b(?:class|id|href|src|alt|type|name|value|placeholder|action|method|rel|charset|content|lang|role|aria-\w+|data-\w+)\b/,
    punctuation: /[<>\/=]/,
    other: /\S+/
  };

  PARSERS.css = {
    whitespace: /\s+/,
    comment: /\/\*[\s\S]*?\*\//,
    string: /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/,
    keyword: /\b(?:import|media|supports|keyframes|font-face|charset|layer|container|property)\b|@[\w-]+/,
    number: /[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?(?:px|em|rem|%|vh|vw|vmin|vmax|ch|ex|lh|fr|s|ms|deg|rad|turn)?/i,
    function: /[\w-]+(?=\s*\()/,
    type: /::?[\w-]+/,
    operator: /[~*^$|>+]/,
    punctuation: /[{}()[\]:;,.#]/,
    variable: /--[\w-]+|\b[\w-]+\b/,
    other: /\S/
  };

  PARSERS.zig = {
    whitespace: /\s+/,
    comment: /\/\/[^\r\n]*/,
    string: /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/,
    keyword: /\b(?:addrspace|align|allowzero|and|anyframe|anytype|asm|async|await|break|callconv|catch|comptime|const|continue|defer|else|enum|errdefer|error|export|extern|fn|for|if|inline|linksection|noalias|nosuspend|opaque|or|orelse|packed|pub|resume|return|struct|suspend|switch|test|threadlocal|try|union|unreachable|usingnamespace|var|volatile|while)\b/,
    type: /\b(?:bool|c_int|c_long|c_longdouble|c_longlong|c_short|c_uint|c_ulong|c_ulonglong|c_ushort|comptime_float|comptime_int|f16|f32|f64|f80|f128|i[0-9]+|isize|noreturn|type|u[0-9]+|usize|void|anyerror)\b/,
    constant: /\b(?:true|false|null|undefined)\b/,
    function: /\b[A-Za-z_]\w*(?=\s*\()/,
    number: /0[xXoObB][\dA-Fa-f_]+|\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?/,
    operator: /[+\-*\/%=<>!&|^~.]+|=>|->|\+\+|--/,
    punctuation: /[()[\]{},;:@]/,
    variable: /\b[A-Za-z_]\w*\b/,
    other: /\S/
  };

  PARSERS.bash = {
    whitespace: /\s+/,
    comment: /#[^\r\n]*/,
    string: /\$?"(?:\\.|[^"\\])*"|'[^']*'|\$'(?:\\.|[^'\\])*'/,
    keyword: /\b(?:if|then|else|elif|fi|case|esac|for|while|until|do|done|in|function|select|time|coproc)\b/,
    constant: /\b(?:true|false)\b/,
    function: /\b[A-Za-z_]\w*(?=\s*\()/,
    number: /\b\d+\b/,
    operator: /[|&;><]+|&&|\|\||>>|<<|[!=]=?/,
    variable: /\$\{?\w+\}?|\$[?@#$!*-]/,
    punctuation: /[()[\]{},;]/,
    other: /\S+/
  };

  PARSERS.yaml = {
    whitespace: /\s+/,
    comment: /#[^\r\n]*/,
    string: /"(?:\\.|[^"\\])*"|'[^']*'/,
    keyword: /\b(?:true|false|yes|no|null|on|off)\b/i,
    number: /[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?/i,
    type: /[\w.-]+(?=\s*:)/,
    operator: /[:|>-]/,
    punctuation: /[[\]{},]/,
    other: /\S+/
  };

  function getParser(language) {
    var rules = PARSERS[language] || PARSERS.html;
    return new Parser(rules);
  }

  function highlightStatic(block) {
    var code = block.querySelector("pre code");
    if (!code) return;

    var language = block.getAttribute("data-language") || "html";
    var parser = getParser(language);
    var tokens = parser.tokenize(code.textContent);
    if (!tokens) return;

    var frag = document.createDocumentFragment();
    for (var i = 0; i < tokens.length; i++) {
      var span = document.createElement("span");
      var cls = parser.identify(tokens[i]);
      if (cls) span.className = cls;
      span.textContent = tokens[i];
      frag.appendChild(span);
    }
    code.textContent = "";
    code.appendChild(frag);
  }

  function initLive(block) {
    var textarea = block.querySelector("textarea");
    if (!textarea) return;

    var language = block.getAttribute("data-language") || "html";
    var parser = getParser(language);
    new TextareaDecorator(textarea, parser);
  }

  function initCopy(block) {
    var btn = block.querySelector("[data-action='copy']");
    if (!btn) return;

    btn.addEventListener("click", function () {
      var text;
      var textarea = block.querySelector("textarea");
      if (textarea) {
        text = textarea.value;
      } else {
        var code = block.querySelector("pre code");
        if (code) text = code.textContent;
      }
      if (!text) return;

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () {
          showCopied(btn);
        });
      }
    });
  }

  function showCopied(btn) {
    var original = btn.textContent;
    btn.textContent = "Copied";
    btn.setAttribute("data-state", "copied");
    setTimeout(function () {
      btn.textContent = original;
      btn.removeAttribute("data-state");
    }, 1500);
  }

  function init() {
    var blocks = document.querySelectorAll(".code-block");
    for (var i = 0; i < blocks.length; i++) {
      var mode = blocks[i].getAttribute("data-mode") || "static";
      if (mode === "live") {
        initLive(blocks[i]);
      } else {
        highlightStatic(blocks[i]);
      }
      initCopy(blocks[i]);
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
