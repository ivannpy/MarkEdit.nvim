if vim.g.loaded_markedit then
    return
end
vim.g.loaded_markedit = 1

local function command(name, fn, desc)
    vim.api.nvim_create_user_command(name, fn, { desc = desc })
end

command("MarkEditOpen", function()
    require("markedit").open()
end, "Open the current buffer in MarkEdit and follow it")

command("MarkEditClose", function()
    require("markedit").close()
end, "Stop following the current buffer in MarkEdit")

command("MarkEditToggle", function()
    require("markedit").toggle()
end, "Toggle following the current buffer in MarkEdit")

command("MarkEditStatus", function()
    require("markedit").show_status()
end, "Show the state of the MarkEdit bridge")

command("MarkEditLog", function()
    require("markedit").show_log()
end, "Show the log of the MarkEdit bridge")
