# Onyx 0.22

## Labels on pull requests

Labels have become the quickest way to tell where a PR stands, above all
when agents open most of them. An agent can leave "ready" or "needs a
human", and Onyx now shows that.

- **Choose which labels to see** in Settings → Pull Requests → Labels on
  open PRs. It lists every label seen on your open GitHub PRs and GitLab
  MRs in the last 30 days, each with its color. Nothing is shown until you
  switch a label on, as with the workflows under CI on open PRs. Most of a
  repo's labels are bookkeeping, and the ones that matter are yours to
  name. Your choice follows you to your other Macs through shared state.
- **The overlay shows them by name, in their colors,** under each PR's
  title.
- **Simple mode shows them as color alone:** a tiny dot per label after
  the branch name, the size of the session list's Claude mark. Hover over
  the line to see the label names. The branch name is shortened before a
  dot is dropped, and dark labels get a faint outline so they show on
  black.
- **The desktop widget and the iPhone's Today page show the same dots** on
  their PR lines.

## Under the hood

- Onyx builds with Xcode 27.
