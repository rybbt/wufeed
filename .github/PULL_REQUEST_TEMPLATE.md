<!--
One sentence: what this change does and the record that asks for it (Issue, kb decision).
Put every other section in a <details> block. Keep a blank line after <summary> and
before </details>, or GitHub does not render the markdown inside.
Delete a section that does not apply. Do not leave it empty.
-->

Closes #

<!--
Network changes (networks, VLANs, zones, bridges, firewall or gateway rules, DNS paths):
draw the change as a Mermaid flowchart. GitHub renders it in place, and it needs no image
hosting, so it works in private repositories. Green = added, red dotted = blocked or
removed, grey = unchanged. Delete this section when the change does not touch the network.
-->
<details open>
<summary><b>Network diagram</b></summary>

```mermaid
flowchart LR
  subgraph NET["network · VLAN · prefix"]
    A["source"]
  end
  B["destination"]
  A -->|"proto, port"| B
  classDef added fill:#e6f6ea,stroke:#1a9a3a,color:#111
  classDef base fill:#f2f2f2,stroke:#888,color:#111
  class A added
  class B base
```

</details>

<details>
<summary><b>Changes</b></summary>

-

</details>

<details>
<summary><b>Effect</b></summary>

<!-- What changes in the rendered or running state: files, rules, resources added or removed. -->

-

</details>

<details>
<summary><b>Apply order (after merge)</b></summary>

1.

</details>

<details>
<summary><b>Risks</b></summary>

-

</details>

<details>
<summary><b>Not in this PR</b></summary>

-

</details>

<details>
<summary><b>Verification</b></summary>

<!-- Commands run and their result. Link CI runs. -->

-

</details>
