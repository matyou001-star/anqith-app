-- أنقذ امتحاني — core schema, RLS, secure PRO logic. NOT YET RUN against a real database.
create extension if not exists pgcrypto;

create type app_role as enum ('student','admin');
create type pay_status as enum ('pending','approved','rejected');

create table profiles (
  id uuid primary key references auth.users on delete cascade,
  account_id text unique not null default upper(substr(encode(gen_random_bytes(5),'hex'),1,8)),
  username text unique, full_name text, email text,
  stage text, grade_id uuid, branch text,
  created_at timestamptz default now()
);
create table user_roles (
  user_id uuid references auth.users on delete cascade,
  role app_role not null default 'student',
  primary key (user_id, role)
);
create table grades (id uuid primary key default gen_random_uuid(), stage text not null, name text not null, sort int default 0);
create table subjects (id uuid primary key default gen_random_uuid(), grade_id uuid references grades on delete cascade, name text not null);
create table chapters (id uuid primary key default gen_random_uuid(), subject_id uuid references subjects on delete cascade, name text not null);
create table topics (id uuid primary key default gen_random_uuid(), chapter_id uuid references chapters on delete cascade, name text not null);
create table exams (id uuid primary key default gen_random_uuid(), user_id uuid references profiles on delete cascade, subject_id uuid references subjects, title text not null, exam_date date not null);
create table study_tasks (id uuid primary key default gen_random_uuid(), user_id uuid references profiles on delete cascade, title text not null, due_date date, done boolean default false);
create table questions (
  id uuid primary key default gen_random_uuid(),
  topic_id uuid references topics on delete set null, subject_id uuid references subjects,
  body text not null, explanation text,
  difficulty text check (difficulty in ('easy','medium','hard')) default 'medium',
  pro_only boolean default false, is_demo boolean default true, created_at timestamptz default now()
);
create table question_options (id uuid primary key default gen_random_uuid(), question_id uuid references questions on delete cascade, body text not null, is_correct boolean default false);
create table quiz_attempts (id uuid primary key default gen_random_uuid(), user_id uuid references profiles on delete cascade, started_at timestamptz default now(), submitted_at timestamptz, score int, total int, question_ids uuid[] not null);
create table attempt_answers (attempt_id uuid references quiz_attempts on delete cascade, question_id uuid, option_id uuid, flagged boolean default false, primary key (attempt_id, question_id));
create table subscription_plans (id uuid primary key default gen_random_uuid(), name text, days int not null, price_iqd int not null, active boolean default true);
create table subscriptions (user_id uuid primary key references profiles on delete cascade, expires_at timestamptz not null, updated_at timestamptz default now());
create table payment_orders (
  id uuid primary key default gen_random_uuid(), user_id uuid not null references profiles, plan_id uuid references subscription_plans,
  days int not null, amount_iqd int not null, method text, tx_reference text not null,
  status pay_status not null default 'pending', admin_note text, decided_by uuid, decided_at timestamptz, created_at timestamptz default now()
);
create table payment_receipts (id uuid primary key default gen_random_uuid(), order_id uuid references payment_orders on delete cascade, storage_path text not null);
create table app_settings (key text primary key, value text);
create table admin_audit_logs (id bigserial primary key, admin_id uuid, action text not null, target_user uuid, details jsonb, created_at timestamptz default now());
create table notifications (id uuid primary key default gen_random_uuid(), user_id uuid references profiles on delete cascade, body text, read boolean default false, created_at timestamptz default now());

create index on questions(subject_id, difficulty);
create index on payment_orders(user_id, status);
create index on quiz_attempts(user_id);
create index on profiles(email); create index on profiles(username);

create or replace function is_admin() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from user_roles where user_id=auth.uid() and role='admin') $$;
create or replace function is_pro(uid uuid) returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from subscriptions where user_id=uid and expires_at>now()) $$;

-- new user -> profile + student role only
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into profiles(id,email,username) values(new.id,new.email,split_part(new.email,'@',1));
  insert into user_roles(user_id,role) values(new.id,'student');
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

-- RLS
alter table profiles enable row level security; alter table user_roles enable row level security;
alter table exams enable row level security; alter table study_tasks enable row level security;
alter table questions enable row level security; alter table question_options enable row level security;
alter table quiz_attempts enable row level security; alter table attempt_answers enable row level security;
alter table subscriptions enable row level security; alter table payment_orders enable row level security;
alter table payment_receipts enable row level security; alter table app_settings enable row level security;
alter table admin_audit_logs enable row level security; alter table notifications enable row level security;
alter table grades enable row level security; alter table subjects enable row level security;
alter table chapters enable row level security; alter table topics enable row level security;
alter table subscription_plans enable row level security;

create policy p_self on profiles for select using (id=auth.uid() or is_admin());
create policy p_upd on profiles for update using (id=auth.uid()) with check (id=auth.uid());
create policy r_self on user_roles for select using (user_id=auth.uid() or is_admin()); -- no insert/update: students can't self-promote
create policy ex_own on exams for all using (user_id=auth.uid()) with check (user_id=auth.uid());
create policy st_own on study_tasks for all using (user_id=auth.uid()) with check (user_id=auth.uid());
create policy cat_read_g on grades for select using (true); create policy cat_read_s on subjects for select using (true);
create policy cat_read_c on chapters for select using (true); create policy cat_read_t on topics for select using (true);
create policy cat_w_g on grades for all using (is_admin()) with check (is_admin());
create policy cat_w_s on subjects for all using (is_admin()) with check (is_admin());
create policy cat_w_c on chapters for all using (is_admin()) with check (is_admin());
create policy cat_w_t on topics for all using (is_admin()) with check (is_admin());
create policy q_admin on questions for all using (is_admin()) with check (is_admin());
create policy qo_admin on question_options for all using (is_admin()) with check (is_admin());
-- students never read questions/options directly (correct answers stay hidden): they use the RPCs below
create policy qa_own on quiz_attempts for select using (user_id=auth.uid() or is_admin());
create policy aa_own on attempt_answers for select using (exists(select 1 from quiz_attempts a where a.id=attempt_id and (a.user_id=auth.uid() or is_admin())));
create policy sub_own on subscriptions for select using (user_id=auth.uid() or is_admin());
create policy plan_read on subscription_plans for select using (true);
create policy plan_admin on subscription_plans for all using (is_admin()) with check (is_admin());
create policy po_own on payment_orders for select using (user_id=auth.uid() or is_admin());
create policy po_ins on payment_orders for insert with check (user_id=auth.uid() and status='pending');
create policy pr_own on payment_receipts for select using (exists(select 1 from payment_orders o where o.id=order_id and (o.user_id=auth.uid() or is_admin())));
create policy pr_ins on payment_receipts for insert with check (exists(select 1 from payment_orders o where o.id=order_id and o.user_id=auth.uid()));
create policy set_read on app_settings for select using (key not like 'secret_%');
create policy set_admin on app_settings for all using (is_admin()) with check (is_admin());
create policy log_admin on admin_audit_logs for select using (is_admin());
create policy nt_own on notifications for all using (user_id=auth.uid()) with check (user_id=auth.uid());

-- Quiz: server picks questions, strips answers
create or replace function start_quiz(p_subject uuid, p_difficulty text, p_count int)
returns table(attempt_id uuid, question_id uuid, body text, options jsonb) language plpgsql security definer set search_path=public as $$
declare ids uuid[]; aid uuid; maxq int := case when is_pro(auth.uid()) then 50 else 10 end;
begin
  if auth.uid() is null then raise exception 'auth'; end if;
  select array_agg(id) into ids from (select id from questions where subject_id=p_subject
    and (p_difficulty is null or difficulty=p_difficulty) and (pro_only=false or is_pro(auth.uid()))
    order by random() limit least(p_count,maxq)) s;
  if ids is null then raise exception 'no questions'; end if;
  insert into quiz_attempts(user_id,question_ids,total) values(auth.uid(),ids,array_length(ids,1)) returning id into aid;
  return query select aid, q.id, q.body,
    (select jsonb_agg(jsonb_build_object('id',o.id,'body',o.body) order by random()) from question_options o where o.question_id=q.id)
  from questions q where q.id=any(ids);
end $$;

create or replace function submit_quiz(p_attempt uuid, p_answers jsonb) -- [{question_id, option_id, flagged}]
returns table(question_id uuid, chosen uuid, correct uuid, is_right boolean, explanation text) language plpgsql security definer set search_path=public as $$
declare a quiz_attempts; sc int;
begin
  select * into a from quiz_attempts where id=p_attempt and user_id=auth.uid() for update;
  if a.id is null then raise exception 'not found'; end if;
  if a.submitted_at is not null then raise exception 'already submitted'; end if;
  insert into attempt_answers(attempt_id,question_id,option_id,flagged)
    select p_attempt,(x->>'question_id')::uuid,nullif(x->>'option_id','')::uuid,coalesce((x->>'flagged')::boolean,false)
    from jsonb_array_elements(p_answers) x where (x->>'question_id')::uuid = any(a.question_ids);
  select count(*) into sc from attempt_answers aa join question_options o on o.id=aa.option_id and o.is_correct where aa.attempt_id=p_attempt;
  update quiz_attempts set submitted_at=now(), score=sc where id=p_attempt;
  return query select q.id, aa.option_id, (select o.id from question_options o where o.question_id=q.id and o.is_correct limit 1),
    coalesce((select o.is_correct from question_options o where o.id=aa.option_id),false),
    case when is_pro(auth.uid()) then q.explanation else left(q.explanation,80) end
  from questions q left join attempt_answers aa on aa.attempt_id=p_attempt and aa.question_id=q.id where q.id=any(a.question_ids);
end $$;

-- Admin: manual PRO (extend/set/revoke) — always audited
create or replace function admin_set_pro(p_user uuid, p_days int default null, p_expires timestamptz default null, p_revoke boolean default false)
returns timestamptz language plpgsql security definer set search_path=public as $$
declare cur timestamptz; nw timestamptz;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  if p_revoke then
    update subscriptions set expires_at=now(), updated_at=now() where user_id=p_user;
    insert into admin_audit_logs(admin_id,action,target_user) values(auth.uid(),'revoke_pro',p_user);
    return now();
  end if;
  select expires_at into cur from subscriptions where user_id=p_user;
  nw := coalesce(p_expires, greatest(coalesce(cur,now()),now()) + make_interval(days=>p_days));
  if nw is null then raise exception 'days or expires required'; end if;
  insert into subscriptions(user_id,expires_at) values(p_user,nw)
    on conflict(user_id) do update set expires_at=excluded.expires_at, updated_at=now();
  insert into admin_audit_logs(admin_id,action,target_user,details) values(auth.uid(),'manual_pro',p_user,jsonb_build_object('days',p_days,'expires',nw));
  return nw;
end $$;

-- Admin: decide payment; row lock prevents double approval
create or replace function admin_decide_payment(p_order uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path=public as $$
declare o payment_orders;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  select * into o from payment_orders where id=p_order for update;
  if o.id is null then raise exception 'not found'; end if;
  if o.status<>'pending' then raise exception 'already decided'; end if;
  update payment_orders set status=case when p_approve then 'approved' else 'rejected' end::pay_status,
    admin_note=p_note, decided_by=auth.uid(), decided_at=now() where id=p_order;
  if p_approve then perform admin_set_pro(o.user_id, o.days); end if;
  insert into admin_audit_logs(admin_id,action,target_user,details) values(auth.uid(),case when p_approve then 'approve_payment' else 'reject_payment' end,o.user_id,jsonb_build_object('order',p_order));
end $$;

revoke all on function admin_set_pro, admin_decide_payment, start_quiz, submit_quiz from public;
grant execute on function admin_set_pro, admin_decide_payment, start_quiz, submit_quiz to authenticated;

-- private receipts bucket
insert into storage.buckets(id,name,public) values('receipts','receipts',false) on conflict do nothing;
create policy rc_ins on storage.objects for insert with check (bucket_id='receipts' and (storage.foldername(name))[1]=auth.uid()::text);
create policy rc_sel on storage.objects for select using (bucket_id='receipts' and ((storage.foldername(name))[1]=auth.uid()::text or is_admin()));

-- seed
insert into subscription_plans(name,days,price_iqd) values('أسبوع',7,2000),('شهر',30,5000),('3 أشهر',90,12000);
insert into app_settings(key,value) values('payment_instructions','[DEMO] حوّل المبلغ عبر زين كاش إلى الرقم الذي يحدده المدير'),('whatsapp',''),('telegram','');
