# R1: a task card gets a picture

risk: low (a rule line in the hub template; no code, secret or data)
Status: **Approved** by the owner's own words (2026-11-28): "when adding clickup tasks, make sure to try and put
screenshots or workflows or user flows", "add it to the rules or wherever", "so every hub has this standard".

## Story
As the owner, I want every task an agent adds to a task board (ClickUp or any other) to carry a screenshot, a workflow
or a user flow, so the person picking it up sees what is meant without asking.

## Acceptance criteria
1. **rule_present** (tests/test_root.sh): templates/hub/CLAUDE.md's shared rules have "A task card gets a picture":
   a screenshot of the screen it is about, or a workflow or user flow; if neither is possible, the task says why; no
   secret or client contact data in a picture.
2. The verification command passes (`bash tests/run.sh`).

## Out of scope
Pushing the rule into hubs made before this change (hub updates from the template, story U1).
