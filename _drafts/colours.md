---
layout: post
title: "Your Terminal will love these Colour Schemes"
assets: "/assets/2024/b7862"
---

<img src="{{ page.assets }}/2001-dave-in-cockpit.jpg" alt="A still from the movie '2001: A Space Odyssey', showing Dave in the cockpit of a spaceship operating the computer panels." class="embed-right">


There's something of value in [Solarized](https://github.com/altercation/solarized)
that I want to unpack. For now, though, please enjoy this humble palette demo:

{% include widgets/palette.html %}

{% capture python_content %}
#Checking if a file exists in two ways
#1- Using the OS module
import os 
exists = os.path.isfile('/path/to/file')
num = 3445567
print(f'{num:,}'*3)
#2- Use the pathlib module for a better performance
from pathlib import Path
config = Path('/path/to/file') 
if config.is_file(): 
    pass
{% endcapture %}
<div style="font-size: 200%">
{% include widgets/textarea-code.html
  id="codeEditor01" content=python_content language="python" tab-size=4 auto-height=true cols=45 %}
</div>

