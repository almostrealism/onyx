/**
 * Every published release, newest first.
 *
 * The exhaustive notes live in docs/release-notes-<version>.md and on the
 * GitHub release. What's here is the readable version — enough for
 * someone deciding whether to update, with a link to the full thing.
 *
 * Adding a release means one entry here: the download URL and the site's
 * "latest" both derive from it, so they can't drift apart.
 */

import { REPO_URL } from './site';

export interface Release {
  version: string;
  /** ISO date, or null while it hasn't shipped yet. */
  date: string | null;
  /** One line on what this release is about. */
  summary: string;
  highlights: string[];
  /** Not yet tagged — shown as upcoming, with no download offered. */
  upcoming?: boolean;
}

export const RELEASES: Release[] = [
  {
    version: '0.16',
    date: null,
    upcoming: true,
    summary:
      'The first release shaped mostly by other people using it — several things here exist because someone asked a question whose real answer was "you can\'t, actually".',
    highlights: [
      'Drag a file onto the terminal to insert its path — uploaded to the remote machine first when the session is remote.',
      'New sessions get a ⌘-number automatically, so keyboard switching works before you have met the favourites system.',
      'Rename and end sessions from the session list.',
      'Two fleet layouts: every remote host as its own row sharing a time axis, or the whole fleet as one pair of charts showing the max across machines.',
      'Watch a whole GitHub owner or GitLab group instead of listing repositories one at a time, and filter drafts in or out.',
      'Page watches: tell me when a page gains or loses a specific line — for the things that are edited rather than announced.',
      'A guided tour on first launch, and under Help afterwards.',
      'Keyboard focus between the terminal and the side panel is fixed: the panel says where typing is going and which key sends it back, clicking the terminal reliably takes the keyboard, and it can no longer end up going nowhere at all.',
      'Fixes: the file browser no longer swallows spaces typed into the terminal, the session idle clock measures output rather than attention, and a 30-second hang on large search results is gone.',
    ],
  },
  {
    version: '0.15',
    date: '2026-08-22',
    summary:
      'Favourite folders became a treemap, AMD GPUs and Ryzen AI NPUs became visible, and the remote-execution layer stopped losing output on hostile shells.',
    highlights: [
      'Favourite folders are drawn as a treemap, so a folder inside a folder looks like one and same-named folders are told apart by what contains them.',
      'GPU stats for AMD hosts through amdgpu’s own counters, plus Ryzen AI NPU residency — no rocm-smi, no root, nothing to install.',
      'The git panel returned to the file browser: branch, staged files and working changes above the listing.',
      'R filters reminders to what is due today or tomorrow, keeping the by-list grouping.',
      'The monitor keeps working when one metric fails — only the failing column reports the error, in the host’s own words.',
      'A signed, notarised app bundle and DMG.',
    ],
  },
];

export const LATEST = RELEASES.find((r) => !r.upcoming)!;

/** The DMG attached to a given release on GitHub. */
export function downloadURL(version: string): string {
  return `${REPO_URL}/releases/download/${version}/Onyx-${version}.dmg`;
}

/** The full notes for a given release. */
export function notesURL(version: string): string {
  return `${REPO_URL}/releases/tag/${version}`;
}
