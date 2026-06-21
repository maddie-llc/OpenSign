# LoKation Sphere e-Sign: Licensing and Legal Considerations

This document summarizes the licensing and legal considerations for self-hosting
OpenSign as the e-signature engine inside the LoKation Sphere portal. It is a
working reference for the engineering and business teams. It is not legal advice;
confirm all conclusions with counsel before production launch.

## Summary

LoKation can self-host OpenSign and offer signing inside the paid Sphere portal.
OpenSign is licensed primarily under the GNU Affero General Public License v3
(AGPL-3.0), which permits commercial use and charging customers. AGPL does,
however, carry network-use obligations and one separately licensed directory that
must be reviewed before launch.

| Concern | Status | Owner |
| --- | --- | --- |
| Commercial use of OpenSign in a paid portal | Permitted under AGPL-3.0 | Legal |
| AGPL Section 13 source-code offer to users | Required; must be implemented | Engineering + Legal |
| `customRoute` separately licensed directory | Open; terms to be obtained | Legal + Engineering |
| Trademark / "OpenSign" name and branding | Decision pending | Business + Legal |
| Data-protection liability shift (self-hosted PII) | New responsibility for LoKation | Compliance |

## License structure

The OpenSign repository splits content into three buckets, defined in the
repository `LICENSE` file.

1. **AGPL-3.0 (most of the codebase).** All content outside the carve-outs below
   is licensed under AGPL-3.0.
2. **`apps/OpenSignServer/cloud/customRoute/` (separate license).** This directory
   is governed by a separate license defined within that directory, not AGPL.
3. **Third-party components.** Each retains the license provided by its owner.

## AGPL-3.0 obligations

AGPL is a strong copyleft license designed for network-served software. The
obligations that apply to a self-hosted, customer-facing deployment are:

- **Commercial use and fees are allowed.** Charging realtors for the Sphere
  portal that includes signing is permitted.
- **Section 13 (network-use source offer).** Because realtors and external
  signers interact with OpenSign over the network, each is a "user" who must be
  offered the complete corresponding source code of the running version,
  including LoKation's modifications. This is typically satisfied with a visible
  "source code" link in the served application.
- **Modifications remain AGPL.** Any change to AGPL-covered OpenSign code stays
  under AGPL and must be included in the Section 13 source offer. This includes
  the planned security hardening and the in-place portions of the branding
  overlay.

### What stays proprietary

LoKation's license independence is preserved by the integration boundary:

- OpenSign runs as a **separate, self-hosted service**.
- The Sphere backend calls OpenSign over its **REST/API boundary** rather than
  importing OpenSign code.

Because of this boundary, the proprietary Sphere portal is **not** a derivative
work of OpenSign and is not subject to AGPL. Runtime artifacts the system
produces — signing certificates, user accounts, signed PDFs, signatures, and
audit trails — are **data, not OpenSign source code**, and belong to LoKation and
its customers.

> Constraint: this independence holds only while Sphere calls OpenSign as an
> external service. If OpenSign code is ever imported or linked directly into the
> Sphere codebase, the portal could become a derivative work. The Sphere
> integration package must remain an API client only.

## The `customRoute` carve-out

The `apps/OpenSignServer/cloud/customRoute/` directory is licensed separately
from AGPL, and its terms are not bundled in the current checkout. This directory
includes routes such as account deletion and document conversion.

- **Action:** obtain and review the directory's license text before production.
- **Decision options:** keep the directory if its terms allow commercial
  deployment, run without it, or obtain commercial terms from OpenSign Labs.

This is the primary open legal item and should be resolved before launch.

## Trademark and branding

LoKation plans to re-brand the signing experience to match Sphere. Branding
assets are not a confidentiality concern and may live in the LoKation source.
Two decisions remain:

- **Name:** fully replace the "OpenSign" name with LoKation Sphere, or retain a
  "Powered by OpenSign" attribution. Confirm the chosen approach respects
  OpenSign trademark usage.
- **Section 13 link:** the "source code available" link must remain reachable in
  the branded application to satisfy AGPL Section 13.

## Data-protection and liability

Self-hosting moves responsibility for confidential signer data in-house. The
deployed system stores personal data including names, emails, phone numbers,
document PDFs, signature images, and audit-trail records (such as IP addresses
and timestamps in the completion certificate).

- LoKation becomes the data custodian previously held by a third-party vendor.
- A data-protection register, retention policy, and breach-response plan are
  required, especially given operations across multiple states.

## Commercial-license option

OpenSign Labs may offer a commercial license that removes the Section 13
source-disclosure obligation. Pursue this if source disclosure to realtors and
signers is undesirable, or if deeper proprietary embedding is wanted.

## Pre-launch legal checklist

- [ ] Obtain and assess the `customRoute` directory license.
- [ ] Implement and verify the AGPL Section 13 source-code offer link.
- [ ] Decide the brand-name and attribution approach with counsel.
- [ ] Confirm all OpenSign modifications are published in the source offer.
- [ ] Complete the data-protection register and retention/breach plans.
- [ ] Obtain counsel sign-off before production launch.

## References

Detailed engineering analysis, evidence, and tracked work items are maintained in
the local planning artifacts (not committed to this repository).
