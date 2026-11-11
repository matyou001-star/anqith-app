-- 004: security review fixes + mock analysis + admin student management + demo purge. NOT YET RUN on a real database.
-- FIX 1: signup failed when two emails shared the same prefix (unique username collision)
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into profiles(id,email,username) values(new.id,new.email,lower(split_part(new.email,'@',1))||'_'||substr(replace(new.id::text,'-',''),1,6));
  insert into user_roles(user_id,role) values(new.id,'student');
  return new;
end $$;

-- FIX 2: students could insert payment orders with arbitrary days/amount; server now forces them from the plan
create or replace function payment_orders_guard() returns trigger language plpgsql security definer set search_path=public as $$
declare d int; p int;
begin
  select days, price_iqd into d, p from subscription_plans where id=new.plan_id and active;
  if d is null then raise exception 'الباقة غير متاحة'; end if;
  if length(trim(coalesce(new.tx_reference,'')))<4 then raise exception 'رقم العملية غير صالح'; end if;
  if (select count(*) from payment_orders where user_id=new.user_id and status='pending')>=3 then raise exception 'لديك 3 طلبات معلّقة، انتظر مراجعتها'; end if;
  new.days:=d; new.amount_iqd:=p; new.status:='pending'; new.admin_note:=null; new.decided_by:=null; new.decided_at:=null;
  return new;
end $$;
drop trigger if exists trg_payment_orders_guard on payment_orders;
create trigger trg_payment_orders_guard before insert on payment_orders for each row execute function payment_orders_guard();
create unique index if not exists uq_payment_tx on payment_orders (lower(trim(tx_reference))) where status<>'rejected';

-- FIX 3: receipts may only reference files inside the student's own folder
drop policy if exists pr_ins on payment_receipts;
create policy pr_ins on payment_receipts for insert with check (storage_path like auth.uid()::text||'/%' and exists(select 1 from payment_orders o where o.id=order_id and o.user_id=auth.uid()));

-- FIX 4: admin audit inserts from the app were silently denied (no insert policy)
create policy log_admin_ins on admin_audit_logs for insert with check (is_admin() and admin_id=auth.uid());

-- FIX 5: scoring cheat — an option from another question could be submitted as "correct". Options must belong to the question.
create or replace function submit_quiz(p_attempt uuid, p_answers jsonb)
returns table(question_id uuid, chosen uuid, correct uuid, is_right boolean, explanation text) language plpgsql security definer set search_path=public as $$
#variable_conflict use_column
declare a quiz_attempts; sc int; pro boolean := is_pro(auth.uid());
begin
  select * into a from quiz_attempts where id=p_attempt and user_id=auth.uid() for update;
  if a.id is null then raise exception 'المحاولة غير موجودة'; end if;
  if a.submitted_at is not null then raise exception 'تم تسليم هذا الاختبار مسبقاً'; end if;
  insert into attempt_answers(attempt_id,question_id,option_id,flagged)
    select p_attempt, y.qid, y.oid, y.fl from (select (x->>'question_id')::uuid as qid, nullif(x->>'option_id','')::uuid as oid, coalesce((x->>'flagged')::boolean,false) as fl from jsonb_array_elements(p_answers) x) y
    where y.qid = any(a.question_ids) and (y.oid is null or exists(select 1 from question_options o where o.id=y.oid and o.question_id=y.qid))
    on conflict do nothing;
  select count(*) into sc from attempt_answers aa join question_options o on o.id=aa.option_id and o.question_id=aa.question_id and o.is_correct where aa.attempt_id=p_attempt;
  update quiz_attempts set submitted_at=now(), score=sc where id=p_attempt;
  return query select q.id, aa.option_id, (select o.id from question_options o where o.question_id=q.id and o.is_correct limit 1),
    coalesce((select o.is_correct from question_options o where o.id=aa.option_id and o.question_id=q.id),false),
    case when pro then q.explanation else left(q.explanation,80) end
  from questions q left join attempt_answers aa on aa.attempt_id=p_attempt and aa.question_id=q.id where q.id=any(a.question_ids);
end $$;
revoke all on function submit_quiz from public; grant execute on function submit_quiz to authenticated;

-- Late mock exams are scored and flagged, but excluded from weakness analysis
create or replace function my_weakness()
returns table(subject text, topic text, answered bigint, correct bigint) language sql stable security definer set search_path=public as $$
  select s.name, coalesce(t.name,'-'), count(*), count(*) filter (where o.is_correct)
  from attempt_answers aa join quiz_attempts a on a.id=aa.attempt_id and a.user_id=auth.uid() and a.submitted_at is not null and not a.late
  join questions q on q.id=aa.question_id join subjects s on s.id=q.subject_id left join topics t on t.id=q.topic_id
  left join question_options o on o.id=aa.option_id and o.question_id=aa.question_id
  where is_pro(auth.uid()) group by s.name,t.name order by (count(*) filter (where o.is_correct))::float/count(*) asc
$$;

create or replace function mock_analysis(p_attempt uuid)
returns table(subject text, topic text, answered bigint, correct bigint) language sql stable security definer set search_path=public as $$
  select s.name, coalesce(t.name,'-'), count(*), count(*) filter (where o.is_correct)
  from quiz_attempts a join attempt_answers aa on aa.attempt_id=a.id join questions q on q.id=aa.question_id
  join subjects s on s.id=q.subject_id left join topics t on t.id=q.topic_id left join question_options o on o.id=aa.option_id and o.question_id=aa.question_id
  where a.id=p_attempt and a.user_id=auth.uid() and a.kind='mock' and a.submitted_at is not null and is_pro(auth.uid())
  group by s.name,t.name order by 1,2
$$;

-- Admin: edit student profile (audited); profiles_guard recomputes onboarded and protects account_id/email
create or replace function profiles_guard() returns trigger language plpgsql as $$
begin
  new.id := old.id; new.account_id := old.account_id; new.email := old.email;
  new.onboarded := new.full_name is not null and length(trim(new.full_name))>=2 and new.grade_id is not null
                   and new.username is not null and length(new.username)>=3;
  return new;
end $$;
create or replace function admin_update_profile(p_user uuid, p_name text, p_username text, p_grade uuid, p_branch text) returns void language plpgsql security definer set search_path=public as $$
declare st text;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  if p_username is null or length(trim(p_username))<3 then raise exception 'اسم المستخدم 3 أحرف على الأقل'; end if;
  select stage into st from grades where id=p_grade;
  update profiles set full_name=trim(p_name), username=lower(trim(p_username)), grade_id=p_grade, stage=st, branch=nullif(trim(p_branch),'') where id=p_user;
  insert into admin_audit_logs(admin_id,action,target_user,details) values(auth.uid(),'update_profile',p_user,jsonb_build_object('username',p_username,'grade',p_grade));
end $$;

-- Admin: remove DEMO content before launch
create or replace function admin_purge_demo() returns int language plpgsql security definer set search_path=public as $$
declare n int;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  delete from questions where is_demo; get diagnostics n = row_count;
  update exams set subject_id=null where subject_id in (select s.id from subjects s join grades g on g.id=s.grade_id where g.name like '[DEMO]%' or g.stage like '[DEMO]%');
  delete from grades where name like '[DEMO]%' or stage like '[DEMO]%';
  update app_settings set value='' where key='payment_instructions' and value like '[DEMO]%';
  insert into admin_audit_logs(admin_id,action,details) values(auth.uid(),'purge_demo',jsonb_build_object('questions',n));
  return n;
end $$;
revoke all on function mock_analysis, admin_update_profile, admin_purge_demo from public;
grant execute on function mock_analysis, admin_update_profile, admin_purge_demo to authenticated;
