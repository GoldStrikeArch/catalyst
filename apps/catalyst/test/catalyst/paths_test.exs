defmodule Catalyst.PathsTest do
  use ExUnit.Case, async: false

  import Catalyst.EnvCase, only: [restore_env: 2]

  alias Catalyst.Paths

  test "an extensions override does not relocate other user data" do
    previous_home = Application.fetch_env(:catalyst, :home)
    previous_extensions = Application.fetch_env(:catalyst, :extensions_dir)
    home = Path.join(System.tmp_dir!(), "paths_home_#{System.unique_integer([:positive])}")
    extensions = Path.join(System.tmp_dir!(), "paths_extensions/extensions")

    on_exit(fn ->
      restore_env(:home, previous_home)
      restore_env(:extensions_dir, previous_extensions)
    end)

    Application.put_env(:catalyst, :home, home)
    Application.put_env(:catalyst, :extensions_dir, extensions)

    assert Paths.home() == home
    assert Paths.extensions() == extensions
    assert Paths.sessions() == Path.join(home, "sessions")
    assert Paths.debug() == Path.join(home, "debug")
    assert Paths.auth() == Path.join(home, "auth.json")
    assert Paths.system_prompt() == Path.join(home, "system_prompt.md")
    assert Paths.prompts() == Path.join(home, "prompts")
    assert Paths.agents() == Path.join(home, "agents")
    assert Paths.workflows() == Path.join(home, "workflows")
    assert Paths.asset_workspace() == Path.join(home, "asset-workspace")
    assert Paths.runtime_assets() == Path.join(home, "runtime-assets")
    assert Paths.join("bin") == Path.join(home, "bin")
  end

  test "an explicit home relocates all default paths together" do
    previous = Application.fetch_env(:catalyst, :home)
    root = Path.join(System.tmp_dir!(), "explicit_home")
    on_exit(fn -> restore_env(:home, previous) end)

    Application.put_env(:catalyst, :home, root)

    assert Paths.home() == root
    assert Paths.system_prompt() == Path.join(root, "system_prompt.md")
    assert Paths.prompts() == Path.join(root, "prompts")
    assert Paths.agents() == Path.join(root, "agents")
    assert Paths.workflows() == Path.join(root, "workflows")
  end

  test "CATALYST_HOME relocates home in a release, but app env wins" do
    previous = Application.fetch_env(:catalyst, :home)
    env_root = Path.join(System.tmp_dir!(), "env_home")
    app_root = Path.join(System.tmp_dir!(), "app_home")

    on_exit(fn ->
      System.delete_env("CATALYST_HOME")
      restore_env(:home, previous)
    end)

    Application.delete_env(:catalyst, :home)
    System.put_env("CATALYST_HOME", env_root)

    assert Paths.home() == env_root
    assert Paths.sessions() == Path.join(env_root, "sessions")

    Application.put_env(:catalyst, :home, app_root)
    assert Paths.home() == app_root
  end
end
