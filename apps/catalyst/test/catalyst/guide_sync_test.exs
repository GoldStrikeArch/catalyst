defmodule Catalyst.GuideSyncTest do
  use ExUnit.Case, async: true

  # `priv/guide.md` (published to ~/.catalyst/guide.md at boot, referenced by
  # the system prompt) is a manual copy of the repo-root `guide.md`. This test
  # is the sync check: when only one is edited, it fails with the fix.
  test "priv/guide.md is byte-identical to the repo-root guide.md" do
    priv = Path.join(to_string(:code.priv_dir(:catalyst)), "guide.md")
    root = Path.expand("../../../../guide.md", __DIR__)

    # In a packaged checkout without the repo root, there is nothing to compare.
    if File.exists?(root) do
      assert File.read!(priv) == File.read!(root),
             "guide.md and priv/guide.md have drifted — run: " <>
               "cp guide.md apps/catalyst/priv/guide.md"
    end
  end
end
