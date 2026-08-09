defmodule Mix.Tasks.Catalyst.Computer.Build do
  @shortdoc "Compile the native macOS computer-use helper (catalyst-input)"
  @moduledoc """
  Compiles `rel/macos/computer_helper.m` into
  `apps/catalyst/priv/bin/catalyst-input`, marks it executable, and ad-hoc
  code-signs it.

      mix catalyst.computer.build

  macOS only (the helper links AppKit / ApplicationServices / Carbon). Fails
  loudly if `cc` is unavailable or the host is not Darwin.

  This is a *dev* build task; it is deliberately **not** wired into `compile`
  (a clang invocation in the warnings-as-errors compile path adds fragility for
  no gain). The release pipeline builds and signs its own copy into the bundle.
  """
  use Mix.Task

  @source_rel "rel/macos/computer_helper.m"
  @output_rel "apps/catalyst/priv/bin/catalyst-input"

  @cc_frameworks ~w(-framework ApplicationServices -framework Carbon
                    -framework Foundation -framework AppKit)

  @impl true
  def run(_args) do
    ensure_darwin!()
    cc = ensure_cc!()
    source = umbrella_path(@source_rel)
    ensure_source!(source)

    output = umbrella_path(@output_rel)
    File.mkdir_p!(Path.dirname(output))

    compile!(cc, source, output)
    File.chmod!(output, 0o755)
    codesign!(output)

    Mix.shell().info("✓ Built #{@output_rel}")
  end

  defp ensure_darwin! do
    case :os.type() do
      {:unix, :darwin} -> :ok
      other -> Mix.raise("catalyst.computer.build: macOS only (host is #{inspect(other)})")
    end
  end

  defp ensure_cc! do
    System.find_executable("cc") ||
      Mix.raise(
        "catalyst.computer.build: `cc` not found on PATH (install Xcode command line tools)"
      )
  end

  defp ensure_source!(source) do
    File.exists?(source) || Mix.raise("catalyst.computer.build: missing source #{source}")
  end

  # Dev builds target the host architecture (the release step pins arm64 to
  # match its `cpu: :aarch64`). Pinning arm64 here would "succeed" on an
  # Intel host and leave a binary that can never run — the forbidden
  # tool-advertised-but-always-errors state.
  defp compile!(cc, source, output) do
    args =
      ["-O2", "-fobjc-arc", "-Wno-deprecated-declarations"] ++
        @cc_frameworks ++ ["-o", output, source]

    cmd!(cc, args, "compile helper")
  end

  defp codesign!(output) do
    cmd!("codesign", ["--force", "-s", "-", output], "ad-hoc sign helper")
  end

  defp cmd!(exe, args, label) do
    case System.cmd(exe, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> Mix.raise("catalyst.computer.build: #{label} failed (#{code}):\n#{out}")
    end
  end

  # The umbrella root is two levels above this app (apps/catalyst) when running
  # under the umbrella; File.cwd! is the umbrella root under `mix` invocation.
  defp umbrella_path(rel) do
    Path.join(File.cwd!(), rel)
  end
end
