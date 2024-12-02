---
layout: default
title: "Plain Text & SVG Images"
---

You can get a lot done with plain-text. Visual limitations (such as being unable
to usefully represent complex images) become strengths when you want a simple
interface. *vim* is popular today precisely because plain-text is enough. It's
not always the best tool, of course, but even with images you'd be surprised.
Here, try it:

<div class="svg-demo">
  <div class="svg-demo-editor">
{% capture svgEditor01_content %}
<circle cx="80" cy="80" r="50" stroke="orange" stroke-width="10" fill="purple" />
{% endcapture %}
{% include widgets/textarea-code.html
  id="svgEditor01" content=svgEditor01_content language="svg" tab-size=2 auto-height=true cols=45 %}
  </div>
  <div class="svg-demo-preview">
    <svg id="svgPreview01" width="25ex" height="15ex"></svg>
  </div>
  <script>
  function updateSvgPreview01() {
    const svgCode = document.getElementById("svgEditor01").value;
    document.getElementById("svgPreview01").innerHTML = svgCode;
  }
  document.getElementById("svgEditor01").addEventListener("input", updateSvgPreview01);
  // Initial SVG render
  updateSvgPreview01();
  </script>
</div>
<div class="svg-demo">
  <div class="svg-demo-editor">
{% capture svgEditor02_content %}
<path stroke="orange"
d="M 10  0   l 0   160
   M 5   10  l 248 0
   M 243 3   l 0   161
   M 0   154 l 250 0
   M 154 5   l 0   144
   M 144 99  l 102 0
   M 188 89  l 0   55
   M 144 120 l 55  0"
/>
<path stroke="purple" stroke-width="4" stroke-linecap="round" fill="none"
d="M 10 154
   c  0  -144 144 -144 144 -144
   c  89  0   89   89  89   89
   c  0   55 -55   55 -55   55
   c -34  0  -34  -34 -34  -34
   c  0  -21  21  -21  21  -21
   c  13  0   13   13  13   13
   c  0   8  -8    8  -8    8
   c -5   0  -5   -5  -5   -5
   c  0  -3   3   -3   3   -3
   c  2   0   2    2   2    2
   c  0   1  -1    1  -1    1
   c -1   0  -1   -1  -1   -1"
/>
{% endcapture %}
{% include widgets/textarea-code.html
  id="svgEditor02" content=svgEditor02_content language="svg" tab-size=2 cols=45 rows=10 %}
  </div>
  <div class="svg-demo-preview">
    <svg id="svgPreview02" width="25ex" height="15ex"></svg>
  </div>
  <script>
  function updateSvgPreview02() {
    const svgCode = document.getElementById("svgEditor02").value;
    document.getElementById("svgPreview02").innerHTML = svgCode;
  }
  document.getElementById("svgEditor02").addEventListener("input", updateSvgPreview02);
  // Initial SVG render
  updateSvgPreview02();
  </script>
</div>
<style>
.svg-demo {
  display: flex;
  flex-direction: row;
  justify-content: center;
  align-items: center;
  align-content: stretch;
}
.svg-demo-editor {
  flex: 1;
  padding-right: 1em;
}
.svg-demo-editor textarea {
  font-family: monospace;
  font-size: 1em;
  padding: 0.5em;
  border: 1px solid #ccc;
  border-radius: 0.25em;
}
.svg-demo-preview {
  flex: 1;
  padding: 1em;
}
.svg-demo-preview svg {
  margin: auto;
  border: 1px solid #ccc;
  border-radius: 0.25ex;
}
</style>
