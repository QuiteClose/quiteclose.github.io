---
layout: stub
title: "CUBE CSS"
tags:
  - css
---
CUBE CSS is an attempt to significantly reduce the *complexity* of your CSS by
by categorising rules according to specific functions that they fulfil. Take a
trivial example:

<div class="side-by-side">
  <textarea>
<!-- Simple CSS Example -->
<style>
.hero-splash {
  width: 100%; height: 50vh;
  font-family: sans-serif; font-size: 2em;
  background-color: red; color: white;
}
.next { background-color: red; color: yellow; }
</style>
<div class="hero-splash">
  <p>Hero Splash</p>
</div>
<div class="next">
  <p>Next</p>
</div>
  </textarea>
  <textarea>
<!-- CUBE CSS Equivalent -->
<style>
:root { font-family: sans-serif; }
.background-red { background-color: red; }
.color-white { color: white; }
.color-yellow { color: yellow; }
.hero-splash { width: 100%; height: 50vh; font-size: 2em; }
</style>
<div class="hero-splash | background-red color-white">
  <p>Hero Splash</p>
</div>
<div class="background-red color-yellow">
  <p>Next</p>
</div>
  </textarea>
</div>

CUBE CSS results in more classes being declared, but each is simpler and easier
to understand. The `hero-splash` class is now a composition which positions
istelf appropriately in the viewport. 

how we can present the CSS in a much denser fashion. This is because you don't
need to read the rule to understand what it does - each rule is simple enough
for its name to express what it does.

One last point, the `|` in `class="hero-splash | background-red color-white"`
has no semantic meaning. The `|` is treated as a class name, but in this case
it is a visual cue to indicate the separate roles.
[Andy Bell's Cube CSS](https://cube.fyi/) uses `[` and `]` to group classes
which feels busy to me, though I suspect it may be more important to follow the
convention.

## CUBE CSS Categorises CSS Declarations
Reducing the scope of rules in this way allows them to be applied more
generally and in combination to create locally specific results. Where possible
rules are declared globally (or has high in the cascade as possible) to allow
not just for simpler CSS but simpler HTML too.

Again, we can refer to [Andy Bell's Cube CSS](https://cube.fyi/) for
descriptions of the four categories,
**Composition**, **Utility**, **Block** and **Exception**, from which the name
CUBE is derived:

<dl class="acrostic">
  <dt>Composition</dt>
  <dd>Layouts that are made up of blocks.</dd>
  <dt>Utility</dt>
  <dd>Classes that are single-purpose (such as defining flow.)</dd>
  <dt>Block</dt>
  <dd>A skeletal component or another (sub) composition.</dd>
  <dt>Exception</dt>
  <dd>Rules that can be toggled for block (e.g. reversed, or shift-right.)</dd>
</dl>

Really, it is simply a strategy for leveraging the cascade by promoting rule
inheritance and combination. CUBE CSS will de-clutter markup whilst inserting
expressive rules that add context. A further benefit is that the rules may be
grouped by function (category) rather than grouped by where they are used. This
makes a CSS codebase easier to navigate and maintain over time.

