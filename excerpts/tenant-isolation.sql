-- Excerpt from the private NeoSAIMS repository (migration 20261019150000_permissions_tenant_scope.sql).
--
-- The problem: assign_permission_group (SECURITY DEFINER, callable by any signed-in user) checked
-- that the caller was allowed to manage roles, but never that the target user belonged to the
-- caller's company. An administrator of one company could change another company's users' roles
-- by id. This migration adds the company check everywhere and stops non-administrators from
-- changing their own permissions. No data is changed.

-- True only when the target user belongs to the caller's company.
CREATE OR REPLACE FUNCTION public.is_same_tenant_user(target uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (SELECT 1 FROM profiles WHERE id = target AND tenant_id = get_user_tenant_id());
$$;
REVOKE EXECUTE ON FUNCTION public.is_same_tenant_user(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_same_tenant_user(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.assign_permission_group(user_uuid uuid, group_name text, assigned_by_uuid uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  -- Signed-in callers may only manage users of their own company (service role: auth.uid() IS NULL).
  IF auth.uid() IS NOT NULL THEN
    IF NOT (COALESCE(is_tenant_admin(), false) OR has_permission(auth.uid(), 'user_management:assign_permissions'::permission_type)) THEN
      RAISE EXCEPTION 'Not allowed to assign roles';
    END IF;
    IF NOT is_same_tenant_user(user_uuid) THEN
      RAISE EXCEPTION 'User not found';   -- same answer as a missing user: no probing other companies
    END IF;
    IF user_uuid = auth.uid() AND NOT COALESCE(is_tenant_admin(), false) THEN
      RAISE EXCEPTION 'Only an administrator can change their own role';
    END IF;
    assigned_by_uuid := auth.uid();       -- never trust the caller-supplied "assigned by"
  END IF;

  -- ... (unchanged: copy the group's permissions to the user)
  RETURN TRUE;
END;
$$;
