-- 003: FREE limits, mock exams, onboarding guard, notifications, admin notes, favorites
alter table quiz_attempts add column if not exists kind text not null default 'practice';
alter table quiz_attempts add column if not exists time_limit_min int;
alter table quiz_attempts add column if not exists late boolean not null default false;
alter table profiles add column if not exists onboarded boolean not null default false;

create or replace function profiles_guard() returns trigger language plpgsql as $$
begin
  new.id := old.id; new.account_id := old.account_id;
  new.onboarded := new.full_name is not null and length(trim(new.full_name))>=2 and new.grade_id is not null
                   and new.username is not null and length(new.username)>=3;
  return new;
end $$;
drop trigger if exists trg_profiles_guard on profiles;
create trigger trg_profiles_guard before update on profiles for each row execute function profiles_guard();

create or replace function attempts_late() returns trigger language plpgsql as $$
begin
  if new.kind='mock' and new.submitted_at is not null and old.submitted_at is null and new.time_limit_min is not null
     and new.submitted_at > new.started_at + make_interval(mins=>new.time_limit_min) + interval '60 seconds' then new.late := true; end if;
  return new;
end $$;
drop trigger if exists trg_attempts_late on quiz_attempts;
create trigger trg_attempts_late before update on quiz_attempts for each row execute function attempts_late();

insert into app_settings(key,value) values('free_daily_quizzes','3'),('free_max_questions','10') on conflict do nothing;

-- start_quiz: enforces onboarding + FREE limits (per-attempt questions, daily attempts) on the server
create or replace function start_quiz(p_subject uuid, p_difficulty text, p_count int)
returns table(attempt_id uuid, question_id uuid, body text, options jsonb) language plpgsql security definer set search_path=public as $$
declare ids uuid[]; aid uuid; pro boolean; maxq int; maxd int; used int;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول'; end if;
  if not exists(select 1 from profiles where id=auth.uid() and onboarded) then raise exception 'أكمل الإعداد الأولي أولاً'; end if;
  if p_count is null or p_count<1 then raise exception 'عدد الأسئلة غير صالح'; end if;
  pro := is_pro(auth.uid());
  if pro then maxq := 50; else
    maxq := coalesce((select nullif(value,'')::int from app_settings where key='free_max_questions'),10);
    maxd := coalesce((select nullif(value,'')::int from app_settings where key='free_daily_quizzes'),3);
    select count(*) into used from quiz_attempts where user_id=auth.uid() and kind='practice'
      and (started_at at time zone 'Asia/Baghdad')::date=(now() at time zone 'Asia/Baghdad')::date;
    if used>=maxd then raise exception 'وصلت إلى حد الاختبارات اليومية في FREE (%). اشترك في PRO للمزيد', maxd; end if;
  end if;
  select array_agg(id) into ids from (select id from questions where subject_id=p_subject
    and (p_difficulty is null or difficulty=p_difficulty) and (pro_only=false or pro)
    order by random() limit least(p_count,maxq)) s;
  if ids is null then raise exception 'لا توجد أسئلة متاحة لهذا الاختيار'; end if;
  insert into quiz_attempts(user_id,question_ids,total,kind) values(auth.uid(),ids,array_length(ids,1),'practice') returning id into aid;
  return query select aid, q.id, q.body,
    (select jsonb_agg(jsonb_build_object('id',o.id,'body',o.body) order by random()) from question_options o where o.question_id=q.id)
  from questions q where q.id=any(ids);
end $$;

-- Mock exam: PRO only, timed (1.5 min/question), server stores limit and flags late submissions
create or replace function start_mock(p_subject uuid default null, p_count int default 20)
returns table(attempt_id uuid, question_id uuid, body text, options jsonb, time_limit_min int) language plpgsql security definer set search_path=public as $$
declare ids uuid[]; aid uuid; n int; lim int;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول'; end if;
  if not exists(select 1 from profiles where id=auth.uid() and onboarded) then raise exception 'أكمل الإعداد الأولي أولاً'; end if;
  if not is_pro(auth.uid()) then raise exception 'الاختبار التجريبي الكامل متاح لمشتركي PRO فقط'; end if;
  n := greatest(10, least(coalesce(p_count,20), 60)); lim := ceil(n*1.5);
  select array_agg(id) into ids from (select id from questions where (p_subject is null or subject_id=p_subject) order by random() limit n) s;
  if ids is null then raise exception 'لا توجد أسئلة كافية'; end if;
  insert into quiz_attempts(user_id,question_ids,total,kind,time_limit_min) values(auth.uid(),ids,array_length(ids,1),'mock',lim) returning id into aid;
  return query select aid, q.id, q.body,
    (select jsonb_agg(jsonb_build_object('id',o.id,'body',o.body) order by random()) from question_options o where o.question_id=q.id), lim
  from questions q where q.id=any(ids);
end $$;
revoke all on function start_quiz, start_mock from public; grant execute on function start_quiz, start_mock to authenticated;

-- admin notes (never visible to students), favorites
create table if not exists admin_notes (id uuid primary key default gen_random_uuid(), user_id uuid references profiles on delete cascade, admin_id uuid, note text not null, created_at timestamptz default now());
create table if not exists favorite_subjects (user_id uuid references profiles on delete cascade, subject_id uuid references subjects on delete cascade, primary key(user_id,subject_id));
alter table admin_notes enable row level security; alter table favorite_subjects enable row level security;
create policy notes_admin on admin_notes for all using (is_admin()) with check (is_admin());
create policy fav_own on favorite_subjects for all using (user_id=auth.uid()) with check (user_id=auth.uid());
create policy fav_admin on favorite_subjects for select using (is_admin());

-- notifications: students can only read and mark read; admin can send; system triggers send automatically
drop policy if exists nt_own on notifications;
create policy nt_sel on notifications for select using (user_id=auth.uid() or is_admin());
create policy nt_upd on notifications for update using (user_id=auth.uid()) with check (user_id=auth.uid());
create policy nt_ins on notifications for insert with check (is_admin());
revoke update on notifications from authenticated; grant update(read) on notifications to authenticated;

create or replace function notify_payment() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.status<>old.status then
    insert into notifications(user_id,body) values(new.user_id, case new.status when 'approved' then 'تمت الموافقة على طلب الدفع وتم تفعيل PRO' else 'تم رفض طلب الدفع. تواصل مع الدعم لمزيد من التفاصيل' end);
  end if; return new;
end $$;
drop trigger if exists trg_notify_payment on payment_orders;
create trigger trg_notify_payment after update of status on payment_orders for each row execute function notify_payment();

create or replace function notify_sub() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into notifications(user_id,body) values(new.user_id, case when new.expires_at<=now() then 'انتهى اشتراك PRO' else 'اشتراكك PRO فعّال حتى '||to_char(new.expires_at at time zone 'Asia/Baghdad','YYYY-MM-DD') end);
  return new;
end $$;
drop trigger if exists trg_notify_sub on subscriptions;
create trigger trg_notify_sub after insert or update on subscriptions for each row execute function notify_sub();
