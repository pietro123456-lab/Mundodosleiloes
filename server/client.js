// Browser helper for connecting the game frontend to the central API.
 // Load this file after defining window.API_BASE (the hosted server URL).
 // Example: window.API_BASE = "https://your-service.onrender.com";
 (() => {
  const base = String(window.API_BASE || "").replace(/\/$/, "");
  const getToken = () => localStorage.getItem("mdleiloes_api_token");
  async function request(path, options = {}) {
    if (!base) throw new Error("Servidor ainda não configurado.");
    const headers = { "Content-Type": "application/json", ...(options.headers || {}) };
    const token = getToken();
    if (token) headers.Authorization = "Bearer " + token;
    const response = await fetch(base + path, { ...options, headers });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(payload.error || "Erro na API.");
    return payload;
  }
  window.MundoAPI = {
    register: async (username, password) => {
      const result = await request("/auth/register", { method: "POST", body: JSON.stringify({ username, password }) });
      localStorage.setItem("mdleiloes_api_token", result.token); return result;
    },
    login: async (username, password) => {
      const result = await request("/auth/login", { method: "POST", body: JSON.stringify({ username, password }) });
      localStorage.setItem("mdleiloes_api_token", result.token); return result;
    },
    logout: () => localStorage.removeItem("mdleiloes_api_token"),
    me: () => request("/me"),
    inventory: () => request("/inventory"),
    buyLuck: multiplier => request("/luck/buy", { method: "POST", body: JSON.stringify({ multiplier }) }),
    openChest: cost => request("/chests/open", { method: "POST", body: JSON.stringify({ cost }) }),
    auctions: () => request("/auctions"),
    createAuction: body => request("/auctions", { method: "POST", body: JSON.stringify(body) }),
    bid: (auctionId, amount) => request("/auctions/" + encodeURIComponent(auctionId) + "/bid", { method: "POST", body: JSON.stringify({ amount }) }),
    adminCoins: (playerId, amount) => request("/admin/coins", { method: "POST", body: JSON.stringify({ playerId, amount }) }),
    adminPlayerLuck: (playerId, multiplier, minutes) => request("/admin/luck/player", { method: "POST", body: JSON.stringify({ playerId, multiplier, minutes }) }),
    adminGlobalLuck: (multiplier, minutes) => request("/admin/luck/global", { method: "POST", body: JSON.stringify({ multiplier, minutes }) })
  };
})();
