package.path = "./?.lua;./tests/?.lua;" .. package.path
local H = require("harness")
for file in io.popen("ls tests/test_*.lua 2>/dev/null"):lines() do
    dofile(file)
end
os.exit(H.run() and 0 or 1)
