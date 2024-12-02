---
layout: default
title: "Simple CSS Checkbox Toggles"
---
{% capture textarea01_content %}
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
{% endcapture %}
{% include widgets/textarea-code.html
  id="textarea01" content=textarea01_content language="svg" tab-size=2 auto-height=true %}
