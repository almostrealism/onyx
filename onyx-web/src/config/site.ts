/**
 * One place for everything the site links to or claims, so a release
 * doesn't require editing five files.
 */

export const REPO_URL = 'https://github.com/almostrealism/onyx';
export const RELEASES_URL = `${REPO_URL}/releases`;
/*
 * The version and its download URL are NOT here. They're derived from
 * RELEASES in ./releases.ts, so shipping a version is one edit and the
 * download button can't end up pointing at a release the list doesn't
 * mention — see LATEST and downloadURL there.
 */

export const REQUIREMENTS = {
  os: 'macOS 14 or later',
  arch: 'Apple Silicon',
  /** Onyx uses tmux on whichever machine hosts the sessions. */
  note: 'tmux on the machines you connect to',
};
