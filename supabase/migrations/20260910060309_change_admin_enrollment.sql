-- Temporary administrator address while the official Yavoi! domain is pending.
delete from private.admin_enrollment where email='administracion@yavoi.com';
insert into private.admin_enrollment(email,claimed_by,claimed_at)
values('admin.yavoi@gmail.com',null,null)
on conflict(email) do update set claimed_by=null,claimed_at=null;
