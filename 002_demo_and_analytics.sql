-- DEMO content only. NOT official Iraqi curriculum.
do $$ declare g uuid; s uuid; c uuid; t uuid; q uuid;
begin
  insert into grades(stage,name,sort) values('[DEMO] تجريبي','[DEMO] صف تجريبي',1) returning id into g;
  insert into subjects(grade_id,name) values(g,'[DEMO] الرياضيات') returning id into s;
  insert into chapters(subject_id,name) values(s,'[DEMO] فصل تجريبي') returning id into c;
  insert into topics(chapter_id,name) values(c,'[DEMO] الجمع والضرب') returning id into t;
  insert into questions(topic_id,subject_id,body,explanation,difficulty,is_demo) values(t,s,'[DEMO] ما ناتج 7 × 8؟','7 × 8 = 56 لأن 7 مكررة 8 مرات.','easy',true) returning id into q;
  insert into question_options(question_id,body,is_correct) values(q,'54',false),(q,'56',true),(q,'58',false),(q,'64',false);
  insert into questions(topic_id,subject_id,body,explanation,difficulty,is_demo) values(t,s,'[DEMO] ما ناتج 15 + 27؟','15 + 27 = 42.','easy',true) returning id into q;
  insert into question_options(question_id,body,is_correct) values(q,'42',true),(q,'41',false),(q,'43',false),(q,'52',false);
  insert into questions(topic_id,subject_id,body,explanation,difficulty,pro_only,is_demo) values(t,s,'[DEMO] ما ناتج 12 × 12؟','12 × 12 = 144.','medium',true,true) returning id into q;
  insert into question_options(question_id,body,is_correct) values(q,'124',false),(q,'144',true),(q,'148',false),(q,'122',false);
end $$;

-- weakness tracking (PRO only), computed server-side
create or replace function my_weakness()
returns table(subject text, topic text, answered bigint, correct bigint) language sql stable security definer set search_path=public as $$
  select s.name, coalesce(t.name,'-'), count(*), count(*) filter (where o.is_correct)
  from attempt_answers aa join quiz_attempts a on a.id=aa.attempt_id and a.user_id=auth.uid() and a.submitted_at is not null
  join questions q on q.id=aa.question_id join subjects s on s.id=q.subject_id left join topics t on t.id=q.topic_id
  left join question_options o on o.id=aa.option_id
  where is_pro(auth.uid()) group by s.name,t.name order by (count(*) filter (where o.is_correct))::float/count(*) asc
$$;
revoke all on function my_weakness from public; grant execute on function my_weakness to authenticated;
