defmodule Catalyst.Extensions.Presenter do
  @moduledoc """
  Pure presentation helpers for extension errors and boot state.

  Runtime code keeps tagged values matchable; user-facing tools and interfaces
  format them at this boundary.
  """

  @doc "Render a tagged extension error as human-readable text."
  @spec format_error(term()) :: String.t()
  def format_error(:self_mod_disabled) do
    "self-modification is disabled on this machine " <>
      "(CATALYST_DISABLE_SELF_MOD / config :catalyst, :allow_self_modification)"
  end

  def format_error({:compile, reason}), do: "compile failed: " <> format_error(reason)
  def format_error({:register, reason}), do: "registration failed: " <> format_error(reason)

  def format_error({:owner_collision, owner, paths}) do
    "multiple extension files normalize to owner #{inspect(owner)}: #{Enum.join(paths, ", ")}"
  end

  def format_error(:no_file), do: "no extension source file found for that owner"

  def format_error(:external_source),
    do: "only files inside the extensions directory can be disabled"

  def format_error(:timeout), do: "timed out"
  def format_error({:exit, reason}), do: "exited: #{inspect(reason)}"

  def format_error({:not_a_tool, module}) do
    "#{inspect(module)} is not a tool " <>
      "(needs name/0, description/0, parameters/0, execute/2)"
  end

  def format_error({:bad_tool_name, reason}), do: "tool name/0 failed: #{inspect(reason)}"

  def format_error({:bad_tool_description, reason}),
    do: "tool description/0 failed: #{inspect(reason)}"

  def format_error({:bad_tool_parameters, reason}),
    do: "tool parameters/0 failed: #{inspect(reason)}"

  def format_error({:bad_tool_mode, reason}),
    do: "tool execution_mode/0 failed: #{inspect(reason)}"

  def format_error({:tool_metadata_timeout, module}),
    do: "tool metadata timed out for #{inspect(module)}"

  def format_error({:tool_metadata_exit, module, reason}),
    do: "tool metadata exited for #{inspect(module)}: #{inspect(reason)}"

  def format_error({:owner_collision, kind, key, existing, attempted}) do
    "#{collision_subject(kind, key)} is already owned by #{inspect(existing)}; " <>
      "#{inspect(attempted)} cannot replace it"
  end

  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason), do: inspect(reason)

  @doc "Render an extension boot status as a user-facing title and explanation."
  @spec describe_boot_status(term()) :: {String.t(), String.t()}
  def describe_boot_status(:ok),
    do: {"Extensions loaded", "The boot-time extension load completed."}

  def describe_boot_status({:waiting_for_host, :web}) do
    {"Waiting for the web extension host",
     "Extensions will load after the web registry finishes wiring its contribution kinds."}
  end

  def describe_boot_status({:safe_mode, :env}) do
    {"Safe mode — extensions were not loaded",
     "CATALYST_SAFE_MODE is set, so loading was skipped on purpose."}
  end

  def describe_boot_status({:safe_mode, :crash_detected}) do
    {"Safe mode — extensions were not loaded",
     "The previous boot died while extensions were active, so this boot skipped them."}
  end

  def describe_boot_status({:load_failed, reason}) do
    {"Extension boot load failed",
     "The boot-time load returned an error: #{format_error(reason)}."}
  end

  def describe_boot_status(_status),
    do: {"Extensions were not loaded", "Extension loading was skipped."}

  defp collision_subject(:context_policy, _key), do: "context policy"

  defp collision_subject(kind, key),
    do: "#{kind |> Atom.to_string() |> String.replace("_", " ")} #{inspect(key)}"
end
