-- ================================================================
-- TAF PUNK — Mise à jour de la logique de jeu
-- (à exécuter APRÈS le script de reset initial : catégories,
--  profiles, submissions, rooms, room_members restent inchangés)
-- ================================================================
-- Règle du jeu (les 2 modes) :
--  - Autant de manches que de joueurs inscrits dans le salon
--  - Chaque manche cible UN joueur pas encore deviné
--  - On joue une chanson au hasard de SA playlist
--  - 4 boutons : le joueur ciblé + 3 leurres
--  - Mauvaise réponse -> ce bouton devient rouge (définitivement,
--    pour toute la manche) + une AUTRE chanson du même joueur
--    ciblé est jouée
--  - Bonne réponse -> manche résolue
--  - Mode MULTI : chacun vote sur son téléphone, 30s par chanson,
--    la première bonne réponse marque le point
--  - Mode GROUPE : un seul écran, l'hôte clique au nom du groupe,
--    pas de score individuel, juste un compteur de manches réussies
-- ================================================================


-- ================================================================
-- 0. RESET de la partie "jeu" du schéma (pas les comptes/playlists)
-- ================================================================
drop table if exists public.round_attempts cascade;
drop table if exists public.answers        cascade; -- ancien nom, si présent
drop table if exists public.rounds         cascade;

drop view if exists public.rounds_public cascade;

drop function if exists public.get_active_round_song(text)        cascade;
drop function if exists public.set_answer_correctness()           cascade;
drop function if exists public.update_participant_score()         cascade;
drop function if exists public.start_next_round(text)             cascade;
drop function if exists public.submit_guess(uuid, uuid)           cascade;
drop function if exists public.advance_song_if_stale(uuid, uuid)  cascade;
drop function if exists public.get_current_round_state(text)      cascade;

drop type if exists round_status cascade;


-- ================================================================
-- 1. ROOMS — ajout du mode et du compteur du mode groupé
-- ================================================================
create type round_status as enum ('PLAYING', 'SOLVED');

alter table public.rooms
  add column if not exists mode text not null default 'MULTI'
    check (mode in ('MULTI', 'GROUP')),
  add column if not exists group_success_count int not null default 0;


-- ================================================================
-- 2. ROUNDS — une manche = un joueur ciblé (pas une chanson fixe)
-- ================================================================
create table public.rounds (
  id                        uuid default uuid_generate_v4() primary key,
  room_code                 text references public.rooms(code) on delete cascade not null,
  round_index               int  not null,
  target_user_id            uuid references public.profiles(id) not null,
  option_user_ids           uuid[] not null,              -- cible + 3 leurres, ordre fixe pour la manche
  eliminated_user_ids       uuid[] not null default '{}', -- boutons déjà rouges (mauvaises réponses)
  current_submission_id     uuid references public.submissions(id) not null,
  played_submission_ids     uuid[] not null default '{}', -- historique des chansons déjà jouées
  status                    round_status not null default 'PLAYING',
  solved_by_user_id         uuid references public.profiles(id), -- null si mode groupe ou si résolu par timeout
  started_at                timestamptz not null default now(),  -- début de la chanson EN COURS (sert au timer)
  created_at                timestamptz not null default now(),
  unique (room_code, round_index)
);

create index on public.rounds (room_code);

-- ================================================================
-- 3. ROUND_ATTEMPTS — historique des réponses (mode multi surtout)
-- ================================================================
create table public.round_attempts (
  id             uuid default uuid_generate_v4() primary key,
  round_id       uuid references public.rounds(id) on delete cascade not null,
  user_id        uuid references public.profiles(id) on delete cascade not null,
  submission_id  uuid references public.submissions(id) not null, -- quelle chanson jouait au moment du clic
  chosen_user_id uuid not null,
  is_correct     boolean not null,
  created_at     timestamptz default now() not null,
  unique (round_id, user_id, submission_id) -- un seul essai par joueur et par chanson jouée
);

create index on public.round_attempts (round_id);


-- ================================================================
-- 4. FONCTION INTERNE : choisir une chanson pas encore jouée
--    pour un joueur ciblé (utilisée par start_next_round et
--    advance_song_if_stale)
-- ================================================================
create or replace function public._pick_unplayed_submission(
  p_target_user_id uuid,
  p_already_played uuid[]
) returns uuid
language sql stable as $$
  select id from public.submissions
  where user_id = p_target_user_id
    and not (id = any(p_already_played))
  order by random()
  limit 1;
$$;


-- ================================================================
-- 5. FONCTION : démarrer la manche suivante
-- Appelée par l'hôte. Choisit un joueur pas encore deviné dans ce
-- salon, 3 leurres, et une première chanson au hasard.
-- ================================================================
create or replace function public.start_next_round(p_room_code text)
returns uuid
language plpgsql security definer as $$
declare
  v_host_id           uuid;
  v_next_index         int;
  v_target_user_id     uuid;
  v_decoy_ids          uuid[];
  v_option_ids         uuid[];
  v_first_submission   uuid;
  v_new_round_id        uuid;
begin
  select host_id into v_host_id from public.rooms where code = p_room_code;
  if v_host_id is null or v_host_id <> auth.uid() then
    raise exception 'Seul l''hôte peut démarrer une manche.';
  end if;

  select coalesce(max(round_index), 0) + 1 into v_next_index
  from public.rounds where room_code = p_room_code;

  -- Un joueur pas encore ciblé dans une manche RÉSOLUE de ce salon,
  -- et qui a au moins une chanson dans sa playlist
  select rm.user_id into v_target_user_id
  from public.room_members rm
  where rm.room_code = p_room_code
    and exists (select 1 from public.submissions s where s.user_id = rm.user_id)
    and rm.user_id not in (
      select target_user_id from public.rounds
      where room_code = p_room_code and status = 'SOLVED'
    )
  order by random()
  limit 1;

  if v_target_user_id is null then
    raise exception 'Plus aucun joueur à faire deviner.';
  end if;

  -- 3 leurres, en priorité parmi ceux pas encore trouvés
  select array_agg(user_id) into v_decoy_ids
  from (
    select rm.user_id
    from public.room_members rm
    where rm.room_code = p_room_code
      and rm.user_id <> v_target_user_id
    order by
      (rm.user_id in (
        select target_user_id from public.rounds
        where room_code = p_room_code and status = 'SOLVED'
      )), -- false (pas encore trouvé) trié avant true
      random()
    limit 3
  ) sub;

  v_option_ids := array_prepend(v_target_user_id, v_decoy_ids);
  -- mélange aléatoire des 4 options
  select array_agg(x order by random()) into v_option_ids
  from unnest(v_option_ids) x;

  v_first_submission := public._pick_unplayed_submission(v_target_user_id, '{}');

  insert into public.rounds (
    room_code, round_index, target_user_id, option_user_ids,
    current_submission_id, played_submission_ids
  ) values (
    p_room_code, v_next_index, v_target_user_id, v_option_ids,
    v_first_submission, array[v_first_submission]
  )
  returning id into v_new_round_id;

  update public.rooms set current_round_index = v_next_index where code = p_room_code;

  return v_new_round_id;
end;
$$;

grant execute on function public.start_next_round(text) to authenticated;


-- ================================================================
-- 6. FONCTION : changer de chanson si l'actuelle est "périmée"
-- (mauvaise réponse, ou timer écoulé côté client). Protégée contre
-- les doubles appels concurrents via la clause WHERE sur l'ancien id.
-- ================================================================
create or replace function public.advance_song_if_stale(
  p_round_id uuid,
  p_expected_submission_id uuid
) returns void
language plpgsql security definer as $$
declare
  v_target_user_id  uuid;
  v_played          uuid[];
  v_next_submission uuid;
begin
  select target_user_id, played_submission_ids
  into v_target_user_id, v_played
  from public.rounds
  where id = p_round_id
    and current_submission_id = p_expected_submission_id
    and status = 'PLAYING';

  if v_target_user_id is null then
    return; -- déjà changé par un autre appel, ou manche déjà résolue
  end if;

  v_next_submission := public._pick_unplayed_submission(v_target_user_id, v_played);

  if v_next_submission is null then
    -- Plus aucune chanson : on clôt la manche automatiquement (timeout/épuisement)
    update public.rounds
    set status = 'SOLVED', solved_by_user_id = null
    where id = p_round_id and current_submission_id = p_expected_submission_id;
  else
    update public.rounds
    set current_submission_id = v_next_submission,
        played_submission_ids = array_append(v_played, v_next_submission),
        started_at = now()
    where id = p_round_id and current_submission_id = p_expected_submission_id;
  end if;
end;
$$;

grant execute on function public.advance_song_if_stale(uuid, uuid) to authenticated;


-- ================================================================
-- 7. FONCTION : proposer une réponse
-- Gère les 2 modes : MULTI (chacun peut essayer, scoring individuel,
-- 30s par chanson) et GROUP (seul l'hôte clique, compteur collectif).
-- ================================================================
create or replace function public.submit_guess(
  p_round_id uuid,
  p_chosen_user_id uuid
) returns jsonb
language plpgsql security definer as $$
declare
  v_room_code    text;
  v_mode         text;
  v_host_id      uuid;
  v_target       uuid;
  v_status       round_status;
  v_submission   uuid;
  v_started_at   timestamptz;
  v_is_correct   boolean;
begin
  select r.room_code, r.target_user_id, r.status, r.current_submission_id, r.started_at,
         ro.mode, ro.host_id
  into v_room_code, v_target, v_status, v_submission, v_started_at, v_mode, v_host_id
  from public.rounds r
  join public.rooms ro on ro.code = r.room_code
  where r.id = p_round_id;

  if v_status is null then
    return jsonb_build_object('ok', false, 'reason', 'round_not_found');
  end if;
  if v_status <> 'PLAYING' then
    return jsonb_build_object('ok', false, 'reason', 'round_already_solved');
  end if;

  if v_mode = 'GROUP' and auth.uid() <> v_host_id then
    return jsonb_build_object('ok', false, 'reason', 'only_host_can_answer_in_group_mode');
  end if;

  if v_mode = 'MULTI' and now() - v_started_at > interval '30 seconds' then
    -- Temps écoulé : on fait avancer la chanson au lieu de compter la réponse
    perform public.advance_song_if_stale(p_round_id, v_submission);
    return jsonb_build_object('ok', false, 'reason', 'time_up');
  end if;

  v_is_correct := (p_chosen_user_id = v_target);

  -- Empêche un double essai sur la même chanson (bouton déjà cliqué)
  insert into public.round_attempts (round_id, user_id, submission_id, chosen_user_id, is_correct)
  values (p_round_id, auth.uid(), v_submission, p_chosen_user_id, v_is_correct)
  on conflict (round_id, user_id, submission_id) do nothing;

  if v_is_correct then
    update public.rounds
    set status = 'SOLVED', solved_by_user_id = auth.uid()
    where id = p_round_id and status = 'PLAYING';

    if v_mode = 'MULTI' then
      update public.room_members
      set score = score + 100
      where room_code = v_room_code and user_id = auth.uid();
    else
      update public.rooms
      set group_success_count = group_success_count + 1
      where code = v_room_code;
    end if;

    return jsonb_build_object('ok', true, 'correct', true);
  else
    -- Ajoute ce joueur aux options éliminées (rouge pour tout le monde),
    -- puis change de chanson
    update public.rounds
    set eliminated_user_ids = array_append(
          eliminated_user_ids,
          p_chosen_user_id
        )
    where id = p_round_id
      and not (p_chosen_user_id = any(eliminated_user_ids));

    perform public.advance_song_if_stale(p_round_id, v_submission);

    return jsonb_build_object('ok', true, 'correct', false);
  end if;
end;
$$;

grant execute on function public.submit_guess(uuid, uuid) to authenticated;


-- ================================================================
-- 8. FONCTION : état sécurisé de la manche en cours (pour l'affichage)
-- Ne révèle jamais target_user_id tant que status <> 'SOLVED'.
-- ================================================================
create or replace function public.get_current_round_state(p_room_code text)
returns jsonb
language plpgsql security definer as $$
declare
  v_result jsonb;
begin
  if not exists (
    select 1 from public.room_members where room_code = p_room_code and user_id = auth.uid()
  ) and not exists (
    select 1 from public.rooms where code = p_room_code and host_id = auth.uid()
  ) then
    return null; -- ni membre, ni hôte de ce salon
  end if;

  select jsonb_build_object(
    'round_id', r.id,
    'round_index', r.round_index,
    'status', r.status,
    'option_user_ids', r.option_user_ids,
    'eliminated_user_ids', r.eliminated_user_ids,
    'started_at', r.started_at,
    'youtube_video_id', s.youtube_video_id,
    'song_title', s.title,
    'target_user_id', case when r.status = 'SOLVED' then r.target_user_id else null end,
    'solved_by_user_id', r.solved_by_user_id
  ) into v_result
  from public.rounds r
  join public.submissions s on s.id = r.current_submission_id
  where r.room_code = p_room_code
  order by r.round_index desc
  limit 1;

  return v_result;
end;
$$;

grant execute on function public.get_current_round_state(text) to authenticated;


-- ================================================================
-- 9. ROW LEVEL SECURITY
-- ================================================================
alter table public.rounds         enable row level security;
alter table public.round_attempts enable row level security;

-- rounds : aucune policy select/insert/update/delete pour les clients.
-- Tout passe par get_current_round_state / start_next_round /
-- submit_guess / advance_song_if_stale (fonctions security definer).

-- round_attempts : chacun voit ses propres essais ; l'hôte voit tout
-- (utile pour un futur écran de stats). Aucun insert direct — tout
-- passe par submit_guess.
create policy "attempts_select" on public.round_attempts
  for select to authenticated using (
    auth.uid() = user_id
    or exists (
      select 1 from public.rounds r
      join public.rooms ro on ro.code = r.room_code
      where r.id = round_attempts.round_id and ro.host_id = auth.uid()
    )
  );
