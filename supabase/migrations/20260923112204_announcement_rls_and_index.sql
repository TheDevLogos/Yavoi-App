create policy yavoi_announcements_deny_direct_access on public.yavoi_announcements
  for all to anon,authenticated using(false) with check(false);
create policy yavoi_announcement_reads_deny_direct_access on public.yavoi_announcement_reads
  for all to anon,authenticated using(false) with check(false);
create index yavoi_announcements_created_by on public.yavoi_announcements(created_by);
