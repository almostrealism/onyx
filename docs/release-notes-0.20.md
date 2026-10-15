# Onyx 0.20

Draft — still being assembled.

## Timing

- **Up to three Timing.app projects at once.** Settings → Monitor → Filter
  Projects now takes up to three top-level projects, in the order you
  choose them (each chip shows its place). Each one gets its own bars and
  numbers:
  - The week chart has one bar per project for each day, side by side,
    each split by that project's subprojects as before. A thin strip in
    the project's color under each bar, matching the dots in the header,
    tells them apart.
  - The legend is the union of every selected project's subprojects (and
    the projects themselves, when time is logged to them directly), most
    time first, whichever project it's under. It wraps onto more lines
    when it needs to.
  - "Hours this week" and "hours per day" become one labeled row per
    project.
  - In the simple layout, the corner widget repeats once per project,
    with the project's name above it.

  "All" still clears the selection, and a single project looks exactly as
  it did before. An existing single-project filter carries over.
- **Projects with no color in Timing keep the same fallback color**: from
  launch to launch, and between a bar and its legend dot. The fallback
  used to come from a hash that changes every launch, and the chart and
  legend each chose their own.
