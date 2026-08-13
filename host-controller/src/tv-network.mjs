function privateRank(address) {
  const parts = address.split('.').map(Number);
  if (parts.length !== 4 || parts.some(part => !Number.isInteger(part) || part < 0 || part > 255)) return 0;
  if (parts[0] === 192 && parts[1] === 168) return 3;
  if (parts[0] === 10) return 2;
  if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return 1;
  return 0;
}

export function selectLanAddress(interfaces) {
  const candidates = Object.values(interfaces)
    .flat()
    .filter(entry => entry && !entry.internal && (entry.family === 'IPv4' || entry.family === 4))
    .map(entry => ({ address: entry.address, rank: privateRank(entry.address) }))
    .filter(entry => entry.rank > 0)
    .sort((left, right) => right.rank - left.rank);
  if (!candidates.length) return null;
  const address = candidates[0].address;
  return { address, url: `http://${address}:8096` };
}
