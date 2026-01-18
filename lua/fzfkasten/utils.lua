local M = {}
function M.join_path(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end
return M