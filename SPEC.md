# blohard protocol

This is the specification of blohard, a message board whose posts live on chain. It covers two
layers that every client and host must agree on:

| layer | what it is | where |
|---|---|---|
| chain protocol | the `Board` contract: messages, replies, reply gates, deletion, signed actions | §3–§5, §8, §9 |
| content | the bytes a message's hash commits to: records, text, references, attachments | §6, §7 |

A third layer, how a client talks to a particular host (uploads, queries, limits), is each host's
own business and is documented by that host.

No protocol string carries the project's name. The contract is `Board`, its signing domain is
`("Board", "1")`, quote links use `post://`, and content headers use `version/1`, so the project
can be renamed without touching anything signed, stored or hashed.

## 1. Overview

- A **message** is a small on-chain record: who wrote it, what it replies to (if anything), when,
  and the keccak-256 hash of its content. The content itself lives off chain, with hosts, and is
  checked against that hash by every reader.
- A **reply** is a message with a parent. Replies form threads.
- A **reply gate** is a contract that decides who may reply to a message. Any message can name
  one, and any author can set a default for all their messages. Gates are read-only.
- The author of a reply's parent may always answer it while it is live, whatever the gates say:
  the **right of response** (§5.4).
- Messages cannot be erased. An author can **delete** (retract) their own message, and the author
  of a message's parent can **remove** it. Both are permanent signals that clients honour.
- Posts and gate changes, including deletion and removal, also have a **signed** form, so someone
  else can pay the gas while authorship stays unforgeable. Revoking signatures and editing lists are
  done by the account itself.

The Board is immutable and ownerless: no admin, no upgrade path, no fees.

## 2. Terms

- **Author:** the account a message belongs to. Any account can be an author, including smart
  accounts.
- **Post:** a message without a parent. **Reply:** a message with one.
- **Gate:** a contract implementing `IReplyGate` (§5).
- **Record:** the bytes a message's content hash commits to (§6).
- **Host:** a service that stores records and, as a gateway, indexes the chain and answers queries.
- **Relayer:** a service that submits signed writes and pays for them.

## 3. Messages

| field | type | notes |
|---|---|---|
| `id` | `uint64` | sequential, starting at 1. `0` means "no parent" |
| `author` | `address` | the caller, or the author named in a signed write once its signature checks out (§4.2) |
| `parentId` | `uint64` | `0` for a post, otherwise an existing message |
| `timestamp` | `uint32` | the block timestamp at inclusion (good until 2106) |
| `contentHash` | `bytes32` | keccak-256 of the exact record bytes (§6) |

Each message takes two storage slots: the content hash, and the author, parent and timestamp packed
into one word. A message's reply gate lives in a separate table, so messages without one never pay
for it. A third table holds each author's default gate.

Messages are stored, not only logged, so other contracts can build on them: check that a message
exists, read its author, or verify that a reply answers a given message (the reply graph stores
upward links only, so contracts verify a reply someone presents rather than enumerating children).
Any message's fields come back from one ordinary contract call, on any node, without log access.

### Events

```solidity
event Posted(address indexed author, uint64 indexed parentId, address indexed parentAuthor,
             uint64 id, bytes32 contentHash, address replyGate);
event ReplyGateChanged(uint64 indexed id, address oldGate, address newGate);
event AuthorGateChanged(address indexed author, address oldGate, address newGate);
event NoncesInvalidated(address indexed author, uint256 wordPos, uint256 mask);
```

`parentAuthor` is the author of the message replied to, or zero for a post. `replyGate` is the gate
set at posting, or zero to use the author's default. The indexed fields support author, parent and
parent-author queries, which is what a gateway needs to build threads and notifications.

## 4. The Board

The full interface, with every error, is in [`src/IBoard.sol`](src/IBoard.sol). In brief:

| function | what it does |
|---|---|
| `post(contentHash, parentId, replyGate, gateData)` | post as the caller |
| `postBySig(author, contentHash, parentId, replyGate, nonce, deadline, sig, gateData)` | post as a signer (§4.2) |
| `setReplyGate(id, gate)` and `setReplyGateBySig(...)` | change a message's gate, delete it, or remove it (§5.2, §5.6) |
| `setAuthorGate(gate)` and `setAuthorGateBySig(...)` | set the author's default gate, or deactivate the account (§5.7) |
| `invalidateNonces(wordPos, mask)` | revoke outstanding signatures (§4.2) |
| `getMessage(id)`, `authorOf(id)`, `exists(id)` | read a message |
| `replyGate(id)`, `authorGate(author)`, `effectiveGate(id)` | read the gates, and the one that would apply now |
| `checkReply(parentId, replier, gateData)` | preview whether a reply would be admitted |
| `nextId()`, `nonceBitmap(author, wordPos)`, `DOMAIN_SEPARATOR()` | the rest of the state |

Two gate addresses are reserved and never called:

- **`TOMBSTONE` (`address(1)`):** on a message, deleted by its author, permanently. As an author's
  default, the account is deactivated, which is reversible.
- **`REMOVED` (`address(2)`):** on a message only, removed by the author of its parent,
  permanently.

`effectiveGate(id)` returns the gate that applies to replies to `id` right now: the message's own
gate if it has one, otherwise its author's default, or zero when neither is set, meaning replies are
open. A message's own gate therefore overrides its author's default, deactivation included. The
reserved addresses come back as they are: `TOMBSTONE` means the message was deleted or, when it has
no gate of its own, that its author is deactivated, and `REMOVED` means the author of its parent
removed it. An unknown id reverts with `MessageNotFound`. The query never calls the gate and takes
no replier, so it cannot say whether a particular account may reply. The right of response (§5.4)
passes a configured gate or a deactivated account, though never a deleted or removed message. Use
`checkReply` to ask about a particular replier.

`checkReply` runs the same admission code as posting, including the right of response and the gate
call, without writing anything. It returns the gate admission depended on, or zero when no gate was
called, and reverts with the posting errors. It authenticates nobody and is only a preview: state,
gas and transaction context can differ at inclusion.

### 4.1 Posting rules

On every `post` and `postBySig`, before an id is assigned or anything stored (`postBySig` first
checks its deadline and signature and uses its nonce; any later failure undoes that):

0. `replyGate` may not be `REMOVED` (`InvalidGate`). `TOMBSTONE` is allowed and makes a message
   that is born deleted.
1. A post (`parentId == 0`) needs nothing more. Posts are never gated; spam control for them
   belongs to whoever pays the gas.
2. The parent must exist (`ParentNotFound`).
3. The parent must not be deleted (`ParentRetracted`) or removed (`ParentRemoved`). Explicit
   deletion and removal always close replies, protected responses included.
4. If the replier is the author of the parent's own parent, the reply is admitted without calling
   any gate: the right of response (§5.4).
5. Otherwise the **effective gate** is the parent's own gate if set, else its author's default
   (§5.7). A deactivated author (`TOMBSTONE` as the default) rejects the reply
   (`ParentRetracted`). Nothing set means anyone may reply.
6. If there is a gate, the Board calls `canReply(parentId, replier, gateData)` on it with
   STATICCALL. The call must succeed and return at least 32 bytes whose first word is exactly `1`.
   Anything else, including a revert, a short or malformed answer, or an address with no code,
   rejects the reply (`GateRejected`).
7. The message is stored and `Posted` is emitted with the parent's actual author.

### 4.2 Signed actions (EIP-712)

`postBySig`, `setReplyGateBySig` and `setAuthorGateBySig` let anyone submit an author's signed
write and pay its gas. The submitter gains nothing else; attribution stays with the signer.

- **Domain:** `("Board", "1", chainId, verifyingContract)`, so a signature is valid on one chain and
  one contract only.
- **Structs:**

  ```text
  Post(address author,bytes32 contentHash,uint64 parentId,address replyGate,uint256 nonce,uint256 deadline)
  SetReplyGate(address author,uint64 id,address gate,uint256 nonce,uint256 deadline)
  SetAuthorGate(address author,address gate,uint256 nonce,uint256 deadline)
  ```

  Every struct names the author, so one signature acts for exactly one identity, even when one key
  controls several accounts. For a removal, the author is the acting signer: the parent's author.
- **Who may sign:** the signature is accepted when it recovers to the author's own key. Failing
  that, an author with code (a smart account, or a key that delegated its code under EIP-7702) is
  asked with ERC-1271's `isValidSignature`, under the same discipline as gate calls: STATICCALL,
  at most 32 bytes read back, anything but the exact magic value refused.
- **Nonces:** unordered and single-use, from a per-author bitmap (word `nonce >> 8`, bit
  `nonce & 0xff`), as in Permit2. Signatures can land in any order, so one stuck write never blocks
  the author's others. All three structs draw from the same bitmap. `deadline` bounds each
  signature's life, and `invalidateNonces(wordPos, mask)` lets the author revoke outstanding ones
  from their own account.
- **Ordering:** posts need none, since ids order them. Two outstanding signed gate changes for the
  same message or author can land in either order; an author who changes their mind waits for the
  first to land, or revokes its nonce before signing the next.
- **Not signed:** `gateData`. Gate proofs are often fetched at submission time against changing
  state, so signing them would make signed replies brittle. A gate must verify anything `gateData`
  claims on its own.

## 5. Reply gates

```solidity
interface IReplyGate {
    function canReply(uint64 parentId, address replier, bytes calldata data)
        external view returns (bool allowed);
}
```

A gate receives the message being replied to and the replier. When posting, the Board has
authenticated the replier; during a `checkReply` preview it has not. `data` is opaque extension
data: the standard gates ignore it, and clients that know no proofs send empty bytes.

### 5.1 Semantics

- **Checked at inclusion.** Every ordinary reply satisfied the gate that applied to its parent at
  the moment it was posted. A protected response (§5.4) skips the gate, so a gate that charges or
  restricts repliers cannot stop one. Nothing promises the rule stays the same afterwards (§5.2).
- **Direct replies only.** A gate governs replies to its own message, not the whole thread (§5.5).
- **Resolution:** the message's own gate, else its author's default, else open. A message that
  should stay open despite its author's default points at a gate that admits everyone.
- **Read-only.** The Board calls gates with STATICCALL, so foreign code can never change state
  inside a Board transaction. A policy that needs state, such as paying to reply, has the replier
  record it in a transaction of their own, and the gate reads that record.

### 5.2 Changing the rules

The author can change a message's gate at any time with `setReplyGate`. Changes apply to future
replies only: existing replies stay on chain. `Posted`, `ReplyGateChanged` and `AuthorGateChanged`
record which gate was in force when.

A gate's behaviour can also change through its own configuration, or through data it reads, such
as someone else's list. Rule stability is something an author gets by choosing a gate that is
immutable and self-contained, not something the protocol promises.

### 5.3 Lists and the standard gates

Gates are ordinary contracts outside the Board. These are the standard ones, deployed at the
addresses in [`deployments.json`](deployments.json):

- **`ListRegistry`:** named lists of addresses, `owner => listId => member`. Anyone keeps any number
  of lists; only the owner writes to theirs. A list's id is the keccak-256 of its name. Membership
  is stored on chain so a gate answers with one read. `Added` and `Removed` events let indexers
  rebuild every list.
- **`AuthorBlocklistGate`:** one shared gate for every author. It reads the parent's author from the
  Board and refuses repliers on that author's list in the registry (the deployed gate uses the list
  named `blocked`). An author points their default gate at it once, then blocks people by adding
  them to their own list.
- **`ClosedReplyGate`:** refuses every ordinary reply ("no new replies"). Protected responses still
  pass (§5.4). Closing a thread this way is reversible, unlike deleting the message.
- **`BlocklistGate`:** refuses members of one fixed list. It is deployed per list, as needed.

### 5.4 The right of response

The author of a reply's parent may always answer that reply, while the reply is live. If Bob
replies to Alice, Alice can answer Bob, whatever the gates on Bob's reply or Bob's account say, and
Bob can then answer Alice. The right follows the authenticated author (including a smart-account
author), not the key or relayer that submitted the write.

- Such an answer is a **protected response**. The person it answers cannot remove it
  (`ProtectedResponse`), even after any of its ancestors is deleted or removed. Its own author can
  still delete it.
- Deletion and removal win: a deleted or removed reply accepts no new replies at all.
- The right needs no extra state. It reads only immutable authors and parent links, so deleting
  ancestors, changing gates, blocking or deactivating an account cannot revoke it.
- Quotes and mentions do not create it.

`effectiveGate` still reports the configured gate; `checkReply` returns zero for an entitled
author.

### 5.5 Direct replies only

A gate covers replies to its message, not replies to those replies. Bob's reply is Bob's message,
and whoever replies to it answers Bob, under Bob's rules. Enforcing a thread-wide rule would let one
author control who may talk to another, would change rules under authors who never agreed to them,
and would cost a walk up the thread on every reply. Thread-wide protection is a reading concern:
clients decide what to show inside a thread.

### 5.6 Deletion and removal

On-chain data cannot be erased, so deletion is a signal carried by the gate field:

- **Delete:** the author sets their message's gate to `TOMBSTONE`.
- **Remove:** the author of a message's **immediate** parent sets its gate to `REMOVED`. This is the
  only change anyone but the author may make to a message. It applies only to direct replies, and
  never to a protected response (§5.4).

Both are permanent. Once either is set, the message accepts no replies (`ParentRetracted` or
`ParentRemoved`) and its gate never changes again (`MessageTombstoned`). Whichever lands first is
final. An author can never mark their own message `REMOVED`, not even a reply to their own post
(`InvalidGate`), so the value always means someone else acted.

The message's fields stay readable and `exists(id)` stays true. Existing replies to it remain on
chain. What readers do:

- Never show a deleted or removed message's content.
- Leave it, and the replies beneath it, out of its parent's reply list and reply count.
- Show it only at its own address, as a placeholder that still lists its surviving direct replies,
  or as context above a surviving reply that a view is showing.

Hosts may stop serving deleted content, but other copies may exist: deletion cannot guarantee
erasure.

### 5.7 Author defaults and deactivation

Each author has one default gate, set with `setAuthorGate`. It governs replies to every message of
theirs that has no gate of its own, including messages posted before the default was set, since
gates are always evaluated at reply time. Pointing it at `AuthorBlocklistGate` makes blocking a
single list write across the whole account.

- **Unset** (zero) means no default: replies are open.
- An address **with no code** is a gate that answers nothing, so replies are refused: a mistyped
  gate closes replies rather than opening them.
- **`TOMBSTONE`** deactivates the account. Ordinary replies to its messages without their own gate
  are refused, and clients show the account as deactivated. Unlike deleting a message, this is
  reversible: setting another default restores everything. The right of response still applies.
- **`REMOVED`** is refused (`InvalidGate`).

Gates are checked when replies are posted, so changing a gate never affects earlier replies on
chain. Clients may still reapply recognised gates when showing earlier replies. The reference
client folds earlier replies from accounts on the parent author's blocklist, whatever gate the
message uses, and never folds protected responses.

### 5.8 Quotes are not replies

A quote is a message whose content references another message with a `post://` link (§7). It is
not an on-chain link, and it is not subject to the quoted message's gate. A reply takes a place in
someone's conversation; a quote stays in the quoter's own space. Quotes are also how a message
travels between chains: replies are always on their parent's chain, where its gate runs.

## 6. Records

Every piece of content is a **record**: one header line, then the body.

```text
version/1 text/plain
<body bytes>
```

- The header ends at the first newline (`0x0A`). A carriage return just before it is ignored.
  Everything after the newline is the body, byte for byte.
- `version/1` is the envelope version. It changes only if the header's own shape changes. A reader
  treats a record with an unknown version as unrecognised.
- The second token is the **media type**, `type/subtype`, lowercase, using letters, digits, `.`,
  `-` and `+`, with no parameters. The header line is at most 128 bytes.
- The content hash is the keccak-256 of the **whole record**, header included, with nothing
  normalised. A record's type is committed to along with its content.
- Text records are UTF-8.

A reader first hashes the bytes and compares them with the expected hash, then parses the header.
Bytes that fail either step are never shown as content, and a media type the reader does not
implement is shown as unrecognised content, never as text.

| media type | what it is | a reader… |
|---|---|---|
| `text/plain` | a message body | renders it as below |
| `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `image/avif` | an attached picture | may show it inline when referenced as an image |
| `image/svg+xml` | a vector picture | must never let it become a document where scripts run; need not show it at all |
| anything else | another kind of attachment | offers it as a download or declines to fetch it, and never renders it inline |

New kinds of content, such as polls or profiles, are new media types. Adding one changes nothing on
chain or in existing clients, which show it as unrecognised until they learn it.

### Message text

A message is a `text/plain` record. Readers render from the original bytes after checking the hash,
never from a form a host derived. The formatting is deliberately small:

- Text, spaces and line breaks are preserved. HTML is text, never markup.
- `*bold*` and `_italics_`: one pair of markers, on one line, not nested. The opening marker must
  not follow a letter or digit and must precede non-whitespace; the closing marker must follow
  non-whitespace and must not precede a letter or digit. Unmatched markers, doubled markers and
  markers after a backslash stay literal.
- HTTP and HTTPS URLs and bare domains become links, bare domains defaulting to HTTPS. The link
  shows its destination, never a substitute label. URLs with credentials and other schemes stay
  text.
- The references in §7 are the only `[label](target)` forms with meaning. All other Markdown
  (headings, lists, code fences, tables) stays ordinary text.

A reader may bound how much of a body it interprets and how many links and previews it shows, as
long as the rest stays visible as text.

## 7. References and attachments

- **`record:0x<hash>`** names a record by its keccak-256 (64 lowercase hex digits). Any host may
  serve it and the reader always verifies it. Attachments use it:
  `![a diagram](record:0x9f3a…)`, `[the data (csv)](record:0x77c1…)`.
- **`account://<address>`** is a mention, usually written `[@alice.eth](account://0x…)`. The label is
  only a hint: readers show the address's current name, or a short address.
- **`post://<chainId>/<messageId>?commit=0x<64 hex digits>`** cites a message. On its own line it is
  a quote, shown as a card; inside a sentence it is a link. The chain id names the canonical Board
  deployment on that chain (§9). The commitment pins the target's immutable fields:

  ```text
  commit = keccak256(abi.encode(author, parentId, timestamp, contentHash))
  types  = (address, uint64, uint32, bytes32)
  ```

  This is standard ABI encoding, four 32-byte words, not packed. A reader compares the pin with the
  located message before showing or attributing the quote. A missing, unreadable or mismatched
  target shows an unavailable placeholder, never a substitute. A malformed pin is never read as the
  shorter unpinned reference. Quotes require the pin; an unpinned locator is only a plain link. A
  deleted or removed quoted message is not shown inside the quote.
- **`https://…`** is an ordinary link to the outside web. A remote image is not covered by any hash
  and reveals the reader to its server, so inline images use `record:` references.

**Attachments** are records referenced from a body with `record:`. The body commits to them by
hash, and the chain commits to the body, so the chain commits to every attachment. Authors upload
the body first, then each attachment. Readers fetch attachments after the text, verify each hash and
dispatch on the media type (§6).

Size limits belong to hosts, which publish their own. So that a message written once can be hosted
anywhere, every host should accept at least this baseline, and clients should stay within it:

| | baseline |
|---|---|
| message record | 4,000 bytes, header included (a host may accept more, never above 1 MiB) |
| attachments per message | 4: the first four `record:` references, in order, without duplicates |
| each attachment | 2 MiB, header included |

## 8. Security considerations

- **Replay.** Signatures are bound to one chain and one contract by the EIP-712 domain, to one
  identity by the author in every struct, and to one use by the nonce bitmap, with a deadline.
- **Only read-only external calls.** The Board's only external calls are STATICCALLs: to a gate,
  and to a contract author's own ERC-1271 check. Neither can change state or move funds. Both read
  back at most 32 bytes, so a hostile callee cannot inflate the caller's memory cost.
- **Gas.** The Board forwards all remaining gas to gates on purpose: fixed allowances break when the
  EVM reprices operations. A hostile gate can still burn the transaction's gas limit, and can behave
  differently in simulation than at inclusion. Clients therefore set an explicit gas limit on every
  write, and relayers send with a fixed limit and simulate with exactly the gas they will send.
- **Reentrancy** is harmless: storage is append-only for messages, ids are assigned after every
  check, and gates run under STATICCALL.
- **A gate can change between preview and inclusion.** The reply then runs under the gate in force
  at inclusion. Gates are read-only, so the worst case is a rejected reply and its gas.
- **Availability.** The chain guarantees that content cannot be altered unnoticed, not that it can
  be found. If every host drops a record, its message is a hash pointing at nothing.
- **Reorgs.** Ids are sequential, so a replaced block can shift them. Clients wait for finality
  before actions that depend on a fresh id, and pinned quotes (§7) detect a changed target.
- **Key loss.** A compromised key can delete its messages for good. Smart accounts with rotatable
  keys are the mitigation; any account can be an author.
- **Lists are public.** Any list enforced on chain, such as a blocklist, can be read by anyone.

## 9. Deployments

Each contract is deployed through the deterministic deployer proxy
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with CREATE2 and a fixed salt, so one version of the
code has one address on every chain. The build pins the compiler and its settings and omits the
metadata hash, so the address depends only on the source.

| contract | salt | constructor arguments |
|---|---|---|
| `Board` | `keccak256("Board v1")` | none |
| `ListRegistry` | `keccak256("ListRegistry v1")` | none |
| `AuthorBlocklistGate` | `keccak256("AuthorBlocklistGate v1")` | the Board, the registry, `keccak256("blocked")` |
| `ClosedReplyGate` | `keccak256("ClosedReplyGate v1")` | none |

The Board deployed this way is **the** Board of each chain. A copy of the code from another deployer
or salt is not the protocol's Board, which is why a `post://` reference needs only a chain id.

Each deployment is its own community: the signing domain binds the chain, and every reply-time check
is a read of the parent chain's state, so threads never cross chains. Identities do, since the same
key has the same address everywhere, and so do quotes.

[`deployments.json`](deployments.json) lists the live addresses, with the block at which the Board
was deployed on each chain: where an indexer starts reading. A test checks every address in it
against the CREATE2 address of the code in this repository, so the two cannot drift apart.
