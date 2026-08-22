defmodule CatalystWeb.Auth.LegacyLoginTest do
  use ExUnit.Case, async: false

  alias CatalystWeb.Auth.LegacyLogin

  setup do
    previous_default = Application.get_env(:catalyst_web, :login_fun)
    previous_grok = Application.get_env(:catalyst_web, :grok_login_fun)

    on_exit(fn ->
      restore(:login_fun, previous_default)
      restore(:grok_login_fun, previous_grok)
    end)

    :ok
  end

  test "provider-pack metadata preserves historical login hooks" do
    default = fn -> :default end
    grok = fn -> :grok end
    Application.put_env(:catalyst_web, :login_fun, default)
    Application.put_env(:catalyst_web, :grok_login_fun, grok)

    assert LegacyLogin.configured("openai-codex") == default
    assert LegacyLogin.configured("xai-grok") == grok
  end

  defp restore(key, nil), do: Application.delete_env(:catalyst_web, key)
  defp restore(key, value), do: Application.put_env(:catalyst_web, key, value)
end
