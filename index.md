---
layout: default
title: "Home"
class: page-home
---


{% if jekyll.environment == "production" %}
<p>This site is under-construction. You won't find much here yet.</p>
{% endif %}

<ul>
  {% for post in site.posts %}
    <li>
      <a href="{{ post.url }}">{{ post.title }}</a>
    </li>
  {% endfor %}
</ul>
