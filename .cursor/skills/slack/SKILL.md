---
name: slack
description: Compose, draft, send, or schedule Slack messages, comms, replies, and canvases via the claude.ai Slack connector. Use for ANY outbound Slack writing (status updates, partner comms, team messages, thread replies, announcements), including drafting for operator review. Covers formatting that survives each path, the draft-and-confirm flow, and post-send obligations.
---

<goal>Deliver Slack messages that render correctly on the path they actually travel (draft vs tool-send vs client copy), reviewed when unreviewed text should not leave, with the posted link relayed back.</goal>

<rules description="Non-negotiable constraints.">
<rule id="prose-standard">Slack is external comms: /no-slop and the writing-style em-dash ban apply in full. Enforced mechanically at the tool boundary by slack-prose-gate.sh (shared lint + semantic judge on every send/draft/schedule/canvas; brevity nudge over ~900 chars). Write brief by default; length is earned only by genuine technical depth.</rule>
<rule id="gfm-only">Write standard GitHub-flavored markdown. NEVER pre-convert to Slack mrkdwn: the connector converts server-side, and a pre-pass double-converts (*bold* renders italic, fences lose highlighting).</rule>
<rule id="no-tables-in-drafts">Messages that start as a draft carry NO markdown tables (slack-prose-gate blocks them). The draft path stores raw text: tables show as pipe soup in the client, survive only an agent tool-send, and die on operator manual send or copy. Restructure as labeled lists ("`0xdac…ec7` (lowercase): order created"). Even in direct tool-sends, prefer lists when recipients may copy or quote the message; a sent table does not survive copy-out of Slack.</rule>
<rule id="draft-first-for-unreviewed">Text the operator has not reviewed goes out as a draft (slack_send_message_draft), not a send, unless the operator explicitly said to send directly.</rule>
<rule id="tool-send-reviewed-drafts">A reviewed draft is posted by the AGENT via slack_send_message with draft_id (this re-runs the markdown converter and deletes the draft). Never tell the operator to hit Send on a draft in the Slack client for formatted content; the client posts stored raw text.</rule>
<rule id="relay-message-link">After every send, reply to the operator with the returned message_link as a clickable link (drafts: the channel_link). Applies to sends, thread replies, scheduled messages, drafts, and canvas writes.</rule>
<rule id="drafts-are-frozen">There is no draft update or delete tool; one attached draft per channel, revisable only by the operator in the Slack client. Two result shapes mean the channel's draft slot is taken: the draft_already_exists error, and a success-shaped create result with NO draft_id in the payload (the connector's silent form of the same conflict; a real create always returns a draft_id). On either: tell the operator plainly that the stale draft in that channel needs their manual delete, and push-notify if they are away. Never relay a draft_id-less create as created, silently skip, send fresh instead, or abandon the correction.</rule>
</rules>

<step id="1" name="Compose">
Draft the text as GFM per `gfm-only`, structured per `no-tables-in-drafts`, sized per `prose-standard`. Code blocks take a language tag for highlighting; a bare ``` fence stays a plain block. Do not put sensitive values in link query params.
</step>

<step id="2" name="Review gate">
Decide the path per `draft-first-for-unreviewed`:
1. Operator already approved the exact text, or asked for a direct send → slack_send_message.
2. Otherwise → slack_send_message_draft, tell the operator where it is (channel_link), and stop until they rule.
</step>

<step id="3" name="Send">
Reviewed draft → slack_send_message with draft_id per `tool-send-reviewed-drafts`. Thread replies set thread_ts (reply_broadcast only when the channel should see it). Externally shared (Slack Connect) channels reject posts; report that instead of retrying.
</step>

<step id="4" name="Relay">
Report the message_link per `relay-message-link`, plus anything undelivered and why.
</step>

<edge-cases>
<case name="draft_already_exists / create result missing draft_id">Handle per `drafts-are-frozen`; both are the same conflict.</case>
<case name="Table genuinely needed">Only a direct tool-send renders it, and it will not survive copy-out. If the content must be copyable or starts as a draft, use a list or attach the table as a code block.</case>
<case name="Gate denies the send">slack-prose-gate returns the lint findings; fix the text and re-send. Do not rephrase to dodge the lint while keeping the violation.</case>
</edge-cases>
