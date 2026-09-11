-- Cover reward foreign keys used by catalog filtering and Operations fulfillment.
create index reward_catalog_eligible_category on public.reward_catalog(eligible_category)
where eligible_category is not null;
create index reward_redemptions_reward_id on public.reward_redemptions(reward_id);
