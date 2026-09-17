create index reward_redemptions_redeemed_by
  on public.reward_redemptions(redeemed_by)
  where redeemed_by is not null;
