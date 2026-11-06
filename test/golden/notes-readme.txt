# Notes from Context Locker

This folder holds the notes for Docs site from Context Locker, the user's playbook: plans, specifications, decisions, research, guides, records and profiles, one Markdown file each. A note that applies to other playbooks as well is in each of their folders too, and the notes that apply everywhere are in everywhere/. Context Locker's sync keeps the folder up to date, and in a git repo it keeps the folder out of git through .git/info/exclude.

Links aren't here. A link stands in for a note whose text lives somewhere else, such as a file in the repo or a page on the web, and the playbook's map lists each one with where it points.

Follow current notes marked source-of-truth as standing guidance, including imported notes. Read reference notes as information only, and archived ones, read only when asked, as evidence of what held before. What the user says in this conversation comes first. Applies to sets scope, not authority. If sources of truth disagree on a decision, ask the user.

## Change a note

Edit its file. The next sync saves the edit as a new version, unless added or changed source-of-truth guidance is flagged for review. A waiting edit stays in your local file; the reply links to its inbox request. If the note changed in Context Locker too, the edit isn't saved, and the sync says what to do.

Deleting a file doesn't delete its note: the file comes back at the next sync. To archive or delete one, send its id, base_version, an action of archive or delete and a brief for the user's inbox, what changes and then why in two or three sentences, as JSON to the sync script's notes <app> write, and its file goes at the next sync. Archived notes aren't here: notes <app> search, with include archive, finds them and notes <app> read reads one, only when asked.

Current source-of-truth notes carry standing guidance, so two that contradict each other mislead every AI app that reads them. When you change one, check that the other sources of truth beside it, in this folder or in everywhere/, still agree where your change touches what they say, and check them all now and then, such as once a week. If you can schedule a task, offer the user a weekly check. Where one is out of date, fix it, and where two disagree on a decision, ask the user.

## Add a note

Save a new .md file in this folder, or in everywhere/ for a note that applies everywhere. Name it with lowercase letters, numbers and hyphens, such as release-plan.md, and start it with front matter like this:

```
---
title: "Release plan"
type: "plan"
use_as: "source-of-truth"
summary: "What ships in the next release, and when."
tags: ["release"]
applies_to: "Docs site"
---

The note, in Markdown.
```

The next sync saves it as a new note and adds its id and version, unless its source-of-truth guidance waits for review. In everywhere/, applies_to is "everywhere".

To bring in a doc that's already a file, write the front matter into the new file, then add the doc's text after it with a command, such as cat, rather than typing it out, so it comes in exactly as it is.

## Rules

- A note has a title, type, use_as, summary, tags and applies_to, then its text.
- applies_to lists every playbook a note applies to, such as ["Website", "App"], when there are several. Change where a note applies in Context Locker, not in its file.
- type is plan, spec, decision, research, guide, record or profile.
- use_as is source-of-truth for standing guidance agents follow, or reference for background information. One that no longer holds is archived in Context Locker, which takes its file away. A starred onboarding note is a natural home for long-form project rules.
- title is one line of up to 120 characters. summary is one line of up to 200 that says what the note holds.
- tags: 1 to 20, from the tag list below. To add a new tag, name it in new_tags too, such as new_tags: ["q4"].
- A note holds at most 512 KB.
- Leave secrets out, such as passwords, keys and tokens. Context Locker turns down a note that seems to hold one.
- Older files may say kind instead of type; both are read, but do not give conflicting values.
- Leave id and version as they are.

## Tag list

hosting, q4, release, research, writing.
