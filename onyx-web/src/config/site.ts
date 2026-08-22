/**
 * One place for everything the site links to or claims, so a release
 * doesn't require editing five files.
 */

export const REPO_URL = 'https://github.com/almostrealism/onyx';
export const RELEASES_URL = `${REPO_URL}/releases`;
export const LATEST_VERSION = '0.15';
/** The DMG attached to the latest GitHub release. */
export const DOWNLOAD_URL = `${REPO_URL}/releases/download/${LATEST_VERSION}/Onyx-${LATEST_VERSION}.dmg`;

export const REQUIREMENTS = {
  os: 'macOS 14 or later',
  arch: 'Apple Silicon',
  /** Onyx uses tmux on whichever machine hosts the sessions. */
  note: 'tmux on the machines you connect to',
};
