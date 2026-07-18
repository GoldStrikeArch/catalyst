defmodule Catalyst.Ext.HookPack do
  @moduledoc false

  use Catalyst.Extension

  alias Catalyst.Content
  alias Catalyst.ExtensionAPI

  @impl true
  def setup(api) do
    :ok = ExtensionAPI.register_hook(api, :transform_context, &__MODULE__.transform/2)
    :ok = ExtensionAPI.register_hook(api, :before_tool_call, &__MODULE__.before_tool/1)
    :ok = ExtensionAPI.register_hook(api, :after_tool_call, &__MODULE__.after_tool/2)
    ExtensionAPI.on(api, &__MODULE__.observe/1)
  end

  @doc false
  def transform(messages, _ctx) do
    notify(:transform_context)
    {:ok, messages}
  end

  @doc false
  def before_tool(ctx) do
    notify({:before_tool_call, ctx.name})
    :cont
  end

  @doc false
  def after_tool({content, details, error?, terminate?}, ctx) do
    notify({:after_tool_call, ctx.name})
    details = Map.put(details || %{}, :flex_hooked, true)
    {:ok, {content ++ Content.text(" [hooked]"), details, error?, terminate?}}
  end

  @doc false
  def observe(event) do
    case Application.get_env(:catalyst, :flex_observer_pid) do
      pid when is_pid(pid) -> send(pid, {:flex_hook_observer, event})
      _other -> :ok
    end
  end

  defp notify(message) do
    case Application.get_env(:catalyst, :flex_observer_pid) do
      pid when is_pid(pid) -> send(pid, {:flex_hook_effect, message})
      _other -> :ok
    end
  end
end
