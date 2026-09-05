module("luci.controller.cf_optimize", package.seeall)
function index()
    entry({"admin", "services", "cf_optimize"}, template("cf_optimize/dashboard"), _("CF 节点优选"), 99)
end
