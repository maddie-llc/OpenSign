# LoKation Sphere e-Sign: Realtor Offboarding and Document Access Plan

This document captures the options for how a departing realtor can access their
previous transactions and signed documents after leaving LoKation Sphere. It is a
discussion starter for the LoKation and Sphere engineering teams. No
implementation decision is made here; this is a future-release consideration.

## The question

When a realtor leaves LoKation, can they still access their previous transactions
and signed documents using their own email?

## Why it is not a simple yes

Both systems identify a realtor by **email address**:

- In Sphere, a realtor's email is their unique login identity (it can be changed,
  but there is a single email per account).
- In OpenSign (the signing engine), email is also the unique user identifier, and
  documents are access-controlled to the user tied to that email.

So continued access depends entirely on one thing:

> **Does the realtor's email remain theirs and reachable after they leave?**

| Email type | After departure | Access outcome |
| --- | --- | --- |
| Personal (their own mailbox) | They keep it | Technically feasible — they can still sign in and receive verification mail |
| LoKation-assigned (e.g., a company mailbox) | Usually deprovisioned | Breaks — both the login identity and any verification email stop working |

Today LoKation does not have a confirmed breakdown of which realtors use personal
versus company-assigned email, and that fact determines which options are viable.

## Two separate concerns

It helps to separate two things that are easy to conflate:

1. **LoKation's record-retention duty.** As a brokerage, LoKation is generally
   required to retain transaction records for a state-specific period (often
   several years), regardless of whether the agent stays. These documents remain
   in LoKation's system either way.
2. **The departing realtor's continued access.** A separate, optional courtesy or
   data-portability layer that lets the individual see or take copies of their own
   transactions.

Also note: buyers and sellers already received their signed copies by email at
signing time, so they are unaffected. This topic is specifically about the
realtor's ongoing access.

## Options

### Option A — Read-only archived account

Keep the realtor's signing account at departure but demote it to read-only. They
continue signing in with the same email to view past documents.

- Works cleanly only if the email persists (personal email).
- Lowest effort.
- Fails for LoKation-assigned emails and leaves an account to secure long-term.

### Option B — "Claim your account" email re-key at offboarding

At the existing offboarding moment, prompt the realtor to move their identity to a
personal email. Because both systems key on email, this re-keys both the Sphere
account and the signing records to the new address before the company mailbox is
removed.

- Converts a company email into a durable personal one while the realtor can still
  be reached.
- Requires an email-change flow that propagates to the signing engine.
- Gives the realtor live, ongoing access.

### Option C — Export package at departure (recommended starting point)

At offboarding, generate a bundle of the realtor's completed documents (signed
PDFs and certificates) and deliver it via a secure download link or to a personal
address they provide.

- Sidesteps the personal-versus-company email problem entirely.
- Strongest data-portability and privacy posture; no orphaned accounts to secure
  indefinitely.
- Provides a snapshot at departure rather than a live login.

### Option D — Decouple identity from email (structural, longer term)

Use a stable identifier (such as the realtor's NRDS member ID, which follows them
across brokerages) as the durable identity, treating email as a changeable
attribute.

- Most robust long term.
- Largest change, and the signing engine still keys on email internally, so it
  would also need an email-remap step.
- Best considered as a future structural improvement, not a first release.

## Recommendation for discussion

- **First release:** Option C (export at departure). It satisfies the realtor's
  need to keep their transactions, avoids the email-identity trap, and keeps no
  long-lived accounts in a confidential-document system.
- **Follow-on:** Option B if the business wants realtors to retain live access
  rather than a one-time export.
- **Only if confirmed:** Option A, viable only if most realtors use personal
  emails.

## Open questions for the LoKation and Sphere teams

1. Do realtors register with personal or LoKation-assigned emails today, or a mix?
   This determines whether read-only account retention (Option A) is even viable.
2. Who owns the documents — LoKation as broker and custodian, the realtor, or
   both? This shapes whether continued access is an obligation or a courtesy.
3. What does "access previous transactions" mean to the business: a permanent
   live login, or receiving their copies?
4. What is the required record-retention period for the relevant states, and does
   it differ from what realtors expect for their own access?

## Status

Captured for team discussion. Not yet scheduled or added to the implementation
plan. To be revisited as a future release once the open questions are answered.

## Related documents

- `architecture-overview.md` — overall e-sign architecture and integration.
- `licensing-and-legal.md` — licensing, data-protection, and retention context.
