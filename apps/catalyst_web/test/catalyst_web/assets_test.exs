defmodule CatalystWeb.AssetsTest do
  # async: false — swaps the global :tailwind profile config.
  use ExUnit.Case, async: false

  alias CatalystWeb.Assets

  @marker "/* catalyst:extensions-source */"

  defp with_tailwind_profile(css_content) do
    dir = Path.join(System.tmp_dir!(), "catalyst_assets_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "assets/css"))
    css = Path.join(dir, "assets/css/app.css")
    File.write!(css, css_content)

    original = Application.get_env(:tailwind, :catalyst_web)
    Application.put_env(:tailwind, :catalyst_web, args: ["--input=assets/css/app.css"], cd: dir)

    on_exit(fn ->
      Application.put_env(:tailwind, :catalyst_web, original)
      File.rm_rf!(dir)
    end)

    css
  end

  test "localize_extension_source rewrites the baked build-machine path" do
    css =
      with_tailwind_profile("""
      @source "../css";
      #{@marker}
      @source "/Users/someone-else/.catalyst/extensions";
      """)

    assert :ok = Assets.localize_extension_source()

    rewritten = File.read!(css)
    assert rewritten =~ ~s(@source "#{Catalyst.Extensions.dir()}";)
    refute rewritten =~ "someone-else"
    # Unmarked @source lines are left alone.
    assert rewritten =~ ~s(@source "../css";)
  end

  test "localize_extension_source is a no-op without the marker (dev css)" do
    css = with_tailwind_profile(~s(@source "../css";\n))
    before = File.read!(css)

    assert :ok = Assets.localize_extension_source()

    assert File.read!(css) == before
  end
end
