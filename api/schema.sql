--
-- PostgreSQL database dump
--

\restrict 1mSOjhAqcINlO9is807cKRoqmJL9GlcSGWuG3Cw6ASMFTpHzomrdKpCYnzfOgko

-- Dumped from database version 17.8 (130b160)
-- Dumped by pg_dump version 18.3

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: user_data; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA user_data;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: email_verifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_verifications (
    id uuid NOT NULL,
    user_id bigint NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id integer DEFAULT nextval('public.users_id_seq'::regclass) NOT NULL,
    password_hash text NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    role text DEFAULT 'user'::text,
    email text,
    email_verified boolean DEFAULT false,
    google_sub text,
    apple_sub text
);


--
-- Name: conversations; Type: TABLE; Schema: user_data; Owner: -
--

CREATE TABLE user_data.conversations (
    id integer NOT NULL,
    transcribed_input text,
    translated_input text,
    suggested_response text,
    translated_suggestion text,
    language text,
    date text,
    "time" text
);


--
-- Name: conversations_id_seq; Type: SEQUENCE; Schema: user_data; Owner: -
--

ALTER TABLE user_data.conversations ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME user_data.conversations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: email_verifications email_verifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_verifications
    ADD CONSTRAINT email_verifications_pkey PRIMARY KEY (id);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: user_data; Owner: -
--

ALTER TABLE ONLY user_data.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: email_verifications_exp_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_verifications_exp_idx ON public.email_verifications USING btree (expires_at);


--
-- Name: email_verifications_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_verifications_user_idx ON public.email_verifications USING btree (user_id);


--
-- Name: users_google_sub_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_google_sub_uniq ON public.users USING btree (google_sub) WHERE (google_sub IS NOT NULL);


--
-- Name: users_apple_sub_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_apple_sub_uniq ON public.users USING btree (apple_sub) WHERE (apple_sub IS NOT NULL);


--
-- Name: email_verifications email_verifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_verifications
    ADD CONSTRAINT email_verifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict 1mSOjhAqcINlO9is807cKRoqmJL9GlcSGWuG3Cw6ASMFTpHzomrdKpCYnzfOgko
