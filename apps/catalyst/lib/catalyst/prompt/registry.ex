defmodule Catalyst.Prompt.Registry do
  @moduledoc "Compatibility surface for prompt overlay registration."

  defdelegate register_prompt(model_key, text), to: Catalyst.Prompt
  defdelegate register_prompt(model_key, text, opts), to: Catalyst.Prompt
  defdelegate register_policy(module), to: Catalyst.Prompt
  defdelegate register_policy(module, opts), to: Catalyst.Prompt
  defdelegate unregister(key), to: Catalyst.Prompt
  defdelegate unregister_policy(), to: Catalyst.Prompt
  defdelegate runtime_text(purpose, model_key), to: Catalyst.Prompt
  defdelegate policy(), to: Catalyst.Prompt
  defdelegate register_extension_prompt(api, model_key, text, opts), to: Catalyst.Prompt
  defdelegate register_extension_prompt_policy(api, module, opts), to: Catalyst.Prompt
end
