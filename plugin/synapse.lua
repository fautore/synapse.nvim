if vim.g.loaded_synapse_nvim then
  return
end
vim.g.loaded_synapse_nvim = true

vim.api.nvim_create_user_command("Synapse", function(command)
  require("synapse").open({ restart = command.bang })
end, {
  bang = true,
  desc = "Open the repository Markdown graph in a Vulkan window",
})

vim.api.nvim_create_user_command("SynapseClose", function()
  require("synapse").close()
end, { desc = "Close the Synapse graph window" })

vim.api.nvim_create_user_command("SynapseBuild", function()
  require("synapse").build()
end, { desc = "Build the Synapse Odin/Vulkan renderer" })

local group = vim.api.nvim_create_augroup("synapse_nvim", { clear = true })

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    require("synapse").close()
  end,
})
