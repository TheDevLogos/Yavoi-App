// Driver and passenger loyalty are available independently of the release track.
export const rewardsEnabledFor = (role) => role === "driver" || role === "passenger";

export function contentAllowedFor(role, item = {}) {
  return true;
}
