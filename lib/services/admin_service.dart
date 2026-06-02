import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:recall_app/core/constants/supabase_constants.dart';
import 'package:recall_app/models/admin_account_summary.dart';
import 'package:recall_app/models/admin_approval_request.dart';
import 'package:recall_app/models/admin_bulk_job.dart';
import 'package:recall_app/models/admin_audit_entry.dart';
import 'package:recall_app/models/admin_compliance_archive.dart';
import 'package:recall_app/models/admin_community_report.dart';
import 'package:recall_app/models/admin_impersonation_session.dart';
import 'package:recall_app/models/admin_impersonation_telemetry.dart';
import 'package:recall_app/models/admin_risk_alert.dart';
import 'package:recall_app/services/supabase_service.dart';

class AdminService {
  final SupabaseService _supabaseService;

  AdminService({required SupabaseService supabaseService})
    : _supabaseService = supabaseService;

  /// Delegates to [SupabaseService.isCurrentUserAdmin] which mirrors
  /// the SQL `is_global_admin()` check (super_admin / org_admin + global scope).
  Future<bool> hasAdminAccess() async {
    return _supabaseService.isCurrentUserAdmin();
  }

  Future<List<AdminAccountSummary>> fetchAccounts({
    String query = '',
    int limit = 100,
  }) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return const [];

    final normalizedQuery = query.trim().toLowerCase();
    final profileRowsRaw = await (() async {
      try {
        final result = await client.rpc(
          'admin_list_accounts',
          params: {'search_text': normalizedQuery, 'row_limit': limit * 20},
        );
        debugPrint(
          '[Admin] admin_list_accounts returned ${(result is List) ? result.length : 0} rows, type=${result.runtimeType}',
        );
        if (result is List && result.isNotEmpty) {
          debugPrint('[Admin] first row: ${result.first}');
        }
        return result;
      } catch (e) {
        debugPrint('[Admin] admin_list_accounts RPC FAILED: $e');
        return const <dynamic>[];
      }
    })();
    final profileRows = profileRowsRaw is List
        ? profileRowsRaw
        : const <dynamic>[];
    final setRowsRaw = await (() async {
      try {
        final result = await client
            .from(SupabaseConstants.studySetsTable)
            .select('user_id, updated_at')
            .order('updated_at', ascending: false)
            .limit(limit * 20);
        debugPrint(
          '[Admin] study_sets query returned ${(result as List).length} rows',
        );
        return result;
      } catch (e) {
        debugPrint('[Admin] study_sets query FAILED: $e');
        return const <dynamic>[];
      }
    })();
    final setRows = setRowsRaw;

    final blockedRowsRaw = await (() async {
      try {
        return await client
            .from(SupabaseConstants.adminAccountBlocksTable)
            .select('target_user_id, blocked_until');
      } catch (_) {
        return const <dynamic>[];
      }
    })();
    final blockedRows = blockedRowsRaw;

    final blockedUserIds = <String>{};
    for (final row in blockedRows) {
      final userId = row['target_user_id'] as String?;
      if (userId == null) continue;
      final blockedUntilRaw = row['blocked_until'] as String?;
      if (blockedUntilRaw == null) {
        blockedUserIds.add(userId);
        continue;
      }
      final blockedUntil = DateTime.tryParse(blockedUntilRaw);
      if (blockedUntil != null &&
          blockedUntil.isAfter(DateTime.now().toUtc())) {
        blockedUserIds.add(userId);
      }
    }

    final roleByUserId = <String, String>{};
    final emailByUserId = <String, String>{};
    for (final row in profileRows) {
      final userId = row['user_id'] as String?;
      if (userId == null || userId.isEmpty) continue;
      final role = (row['role'] as String? ?? 'student').trim().toLowerCase();
      final email = (row['email'] as String? ?? '').trim();
      roleByUserId[userId] = role == 'teacher' ? 'teacher' : 'student';
      emailByUserId[userId] = email;
    }

    final map = <String, ({int count, DateTime? lastAt})>{};
    for (final row in profileRows) {
      final userId = row['user_id'] as String?;
      if (userId == null || userId.isEmpty) continue;
      if (normalizedQuery.isNotEmpty &&
          !userId.toLowerCase().contains(normalizedQuery)) {
        continue;
      }
      final updatedAt = DateTime.tryParse(row['updated_at'] as String? ?? '');
      final current = map[userId];
      if (current == null) {
        map[userId] = (count: 0, lastAt: updatedAt);
      } else {
        final last = current.lastAt;
        map[userId] = (
          count: current.count,
          lastAt:
              (updatedAt != null && (last == null || updatedAt.isAfter(last)))
              ? updatedAt
              : last,
        );
      }
    }

    for (final row in setRows) {
      final userId = row['user_id'] as String?;
      if (userId == null) continue;
      if (normalizedQuery.isNotEmpty &&
          !userId.toLowerCase().contains(normalizedQuery)) {
        continue;
      }
      final updatedAt = DateTime.tryParse(row['updated_at'] as String? ?? '');
      final current = map[userId];
      if (current == null) {
        map[userId] = (count: 1, lastAt: updatedAt);
      } else {
        final last = current.lastAt;
        map[userId] = (
          count: current.count + 1,
          lastAt:
              (updatedAt != null && (last == null || updatedAt.isAfter(last)))
              ? updatedAt
              : last,
        );
      }
    }

    final accounts =
        map.entries
            .map(
              (e) => AdminAccountSummary(
                userId: e.key,
                email: emailByUserId[e.key] ?? '',
                studySetCount: e.value.count,
                lastActivityAt: e.value.lastAt,
                isBlocked: blockedUserIds.contains(e.key),
                classroomRole: roleByUserId[e.key] == 'teacher'
                    ? 'teacher'
                    : 'student',
              ),
            )
            .toList()
          ..sort((a, b) {
            final ad = a.lastActivityAt;
            final bd = b.lastActivityAt;
            if (ad == null && bd == null) return 0;
            if (ad == null) return 1;
            if (bd == null) return -1;
            return bd.compareTo(ad);
          });

    debugPrint(
      '[Admin] Final account list: ${accounts.length} accounts (showing ${accounts.take(limit).length})',
    );
    for (final a in accounts.take(5)) {
      debugPrint(
        '[Admin]   - ${a.email} (${a.userId.substring(0, 8)}...) sets=${a.studySetCount}',
      );
    }
    return accounts.take(limit).toList();
  }

  Future<List<AdminCommunityReport>> fetchCommunityReports() async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return const [];
    final rows = await client.rpc('admin_list_community_reports');
    return (rows as List)
        .map(
          (row) => AdminCommunityReport.fromJson(row as Map<String, dynamic>),
        )
        .toList();
  }

  Future<void> resolveCommunityReports({
    required String publicSetId,
    required String action,
    String reason = '',
  }) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return;
    await client.rpc(
      'admin_resolve_community_reports',
      params: {
        'target_set_id': publicSetId,
        'resolution_action': action,
        'reason': reason,
      },
    );
  }

  Future<void> setUserClassroomRole({
    required String targetUserId,
    required String role,
    String reason = 'manual_admin_action',
  }) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return;
    final normalized = role.trim().toLowerCase() == 'teacher'
        ? 'teacher'
        : 'student';
    await client.rpc(
      'admin_set_profile_role',
      params: {
        'target_user_id': targetUserId,
        'new_role': normalized,
        'reason': reason,
      },
    );
  }

  Future<void> blockUser({
    required String targetUserId,
    required String reason,
    DateTime? blockedUntil,
  }) async {
    final actor = _supabaseService.currentUser;
    final client = _supabaseService.clientOrNull;
    if (actor == null || client == null) return;

    await client.from(SupabaseConstants.adminAccountBlocksTable).insert({
      'target_user_id': targetUserId,
      'blocked_by': actor.id,
      'reason': reason,
      'blocked_until': blockedUntil?.toIso8601String(),
    });
    await _writeAudit(
      action: 'block_user',
      targetUserId: targetUserId,
      reason: reason,
      metadata: {'blocked_until': blockedUntil?.toIso8601String()},
    );
  }

  Future<void> unblockUser({
    required String targetUserId,
    required String reason,
  }) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return;
    await client
        .from(SupabaseConstants.adminAccountBlocksTable)
        .delete()
        .eq('target_user_id', targetUserId);
    await _writeAudit(
      action: 'unblock_user',
      targetUserId: targetUserId,
      reason: reason,
    );
  }

  Future<void> forceSignOutAllSessions({
    required String targetUserId,
    String reason = '',
  }) async {
    final actor = _supabaseService.currentUser;
    final client = _supabaseService.clientOrNull;
    if (actor == null || client == null) return;

    await client.from(SupabaseConstants.adminBulkJobsTable).insert({
      'actor_user_id': actor.id,
      'job_type': 'signout_user',
      'payload': {'target_user_id': targetUserId},
      'status': 'pending',
      'summary': 'Force sign-out queued for user $targetUserId',
    });
    await _writeAudit(
      action: 'force_signout_user',
      targetUserId: targetUserId,
      reason: reason,
    );
  }

  Future<void> assignRole({
    required String adminUserId,
    required String roleKey,
    String scopeType = 'global',
    String? scopeId,
  }) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return;

    await client.from(SupabaseConstants.adminRoleBindingsTable).upsert({
      'admin_user_id': adminUserId,
      'role_key': roleKey,
      'scope_type': scopeType,
      'scope_id': scopeId,
      'created_by': _supabaseService.currentUser?.id,
    });
    await _writeAudit(
      action: 'assign_role',
      targetUserId: adminUserId,
      reason: 'role=$roleKey, scope_type=$scopeType, scope_id=${scopeId ?? ''}',
    );
  }

  Future<List<AdminAuditEntry>> fetchAuditEntries({int limit = 100}) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return const [];

    final rows = await client
        .from(SupabaseConstants.adminAuditLogsTable)
        .select('id, actor_user_id, target_user_id, action, reason, created_at')
        .order('created_at', ascending: false)
        .limit(limit);

    return (rows as List)
        .map(
          (row) => AdminAuditEntry(
            id: row['id'] as int? ?? 0,
            actorUserId: row['actor_user_id'] as String? ?? '',
            targetUserId: row['target_user_id'] as String?,
            action: row['action'] as String? ?? 'unknown',
            reason: row['reason'] as String? ?? '',
            createdAt:
                DateTime.tryParse(row['created_at'] as String? ?? '') ??
                DateTime.now().toUtc(),
          ),
        )
        .toList();
  }

  Future<List<AdminRiskAlert>> fetchRiskAlerts({int limit = 100}) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return const [];
    final rows = await client
        .from(SupabaseConstants.adminRiskAlertsTable)
        .select(
          'id, target_user_id, risk_type, severity, status, summary, created_at',
        )
        .order('created_at', ascending: false)
        .limit(limit);

    return (rows as List)
        .map(
          (row) => AdminRiskAlert(
            id: row['id'] as int? ?? 0,
            targetUserId: row['target_user_id'] as String? ?? '',
            riskType: row['risk_type'] as String? ?? 'unknown',
            severity: row['severity'] as String? ?? 'medium',
            status: row['status'] as String? ?? 'open',
            summary: row['summary'] as String? ?? '',
            createdAt:
                DateTime.tryParse(row['created_at'] as String? ?? '') ??
                DateTime.now().toUtc(),
          ),
        )
        .toList();
  }

  Future<void> createApprovalRequest({
    required String actionType,
    required String reason,
    required Map<String, dynamic> payload,
  }) async {
    final actor = _supabaseService.currentUser;
    final client = _supabaseService.clientOrNull;
    if (actor == null || client == null) return;

    await client.from(SupabaseConstants.adminApprovalRequestsTable).insert({
      'requested_by': actor.id,
      'action_type': actionType,
      'reason': reason,
      'payload': payload,
      'status': 'pending',
    });
    await _writeAudit(
      action: 'create_approval_request',
      targetUserId: actor.id,
      reason: 'action=$actionType, reason=$reason',
      metadata: payload,
    );
  }

  Future<void> requestMfaEnforcement({
    required String targetUserId,
    String reason = 'security_policy_enforcement',
  }) async {
    await createApprovalRequest(
      actionType: 'enforce_mfa',
      reason: reason,
      payload: {'target_user_id': targetUserId},
    );
  }

  Future<List<AdminApprovalRequest>> fetchApprovalRequests({
    String? status,
    int limit = 100,
  }) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return const [];

    var query = client
        .from(SupabaseConstants.adminApprovalRequestsTable)
        .select(
          'id, requested_by, action_type, payload, reason, status, '
          'approved_by, approved_at, rejected_by, rejected_at, created_at',
        );

    if (status != null && status.trim().isNotEmpty) {
      query = query.eq('status', status.trim());
    }

    final rows = await query.order('created_at', ascending: false).limit(limit);
    return (rows as List).map((row) {
      final payloadRaw = row['payload'];
      final payload = payloadRaw is Map
          ? Map<String, dynamic>.from(payloadRaw)
          : const <String, dynamic>{};
      return AdminApprovalRequest(
        id: row['id'] as int? ?? 0,
        requestedBy: row['requested_by'] as String? ?? '',
        actionType: row['action_type'] as String? ?? 'unknown',
        payload: payload,
        reason: row['reason'] as String? ?? '',
        status: row['status'] as String? ?? 'pending',
        approvedBy: row['approved_by'] as String?,
        approvedAt: DateTime.tryParse(row['approved_at'] as String? ?? ''),
        rejectedBy: row['rejected_by'] as String?,
        rejectedAt: DateTime.tryParse(row['rejected_at'] as String? ?? ''),
        createdAt:
            DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now().toUtc(),
      );
    }).toList();
  }

  Future<void> approveRequest({
    required int requestId,
    String reason = 'approved_by_admin',
  }) async {
    final actor = _supabaseService.currentUser;
    final client = _supabaseService.clientOrNull;
    if (actor == null || client == null) return;

    final requestRow = await client
        .from(SupabaseConstants.adminApprovalRequestsTable)
        .select('action_type, payload, requested_by')
        .eq('id', requestId)
        .maybeSingle();
    if (requestRow == null) return;

    await client
        .from(SupabaseConstants.adminApprovalRequestsTable)
        .update({
          'status': 'approved',
          'approved_by': actor.id,
          'approved_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', requestId)
        .eq('status', 'pending');

    final actionType = requestRow['action_type'] as String? ?? 'unknown';
    final payloadRaw = requestRow['payload'];
    final payload = payloadRaw is Map
        ? Map<String, dynamic>.from(payloadRaw)
        : const <String, dynamic>{};
    await _queueApprovedAction(
      actionType: actionType,
      payload: payload,
      approvedByUserId: actor.id,
    );

    final targetUserId =
        payload['target_user_id'] as String? ??
        (requestRow['requested_by'] as String? ?? actor.id);
    await _writeAudit(
      action: 'approve_request',
      targetUserId: targetUserId,
      reason: 'request_id=$requestId, action_type=$actionType, reason=$reason',
      metadata: payload,
    );
  }

  Future<void> rejectRequest({
    required int requestId,
    required String rejectReason,
  }) async {
    final actor = _supabaseService.currentUser;
    final client = _supabaseService.clientOrNull;
    if (actor == null || client == null) return;

    final requestRow = await client
        .from(SupabaseConstants.adminApprovalRequestsTable)
        .select('payload, requested_by')
        .eq('id', requestId)
        .maybeSingle();
    if (requestRow == null) return;

    await client
        .from(SupabaseConstants.adminApprovalRequestsTable)
        .update({
          'status': 'rejected',
          'rejected_by': actor.id,
          'rejected_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', requestId)
        .eq('status', 'pending');

    final payloadRaw = requestRow['payload'];
    final payload = payloadRaw is Map
        ? Map<String, dynamic>.from(payloadRaw)
        : const <String, dynamic>{};
    final targetUserId =
        payload['target_user_id'] as String? ??
        (requestRow['requested_by'] as String? ?? actor.id);
    await _writeAudit(
      action: 'reject_request',
      targetUserId: targetUserId,
      reason: 'request_id=$requestId, reason=$rejectReason',
      metadata: payload,
    );
  }

  Future<List<AdminImpersonationSession>> fetchImpersonationSessions({
    bool activeOnly = false,
    int limit = 100,
  }) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return const [];

    var query = client
        .from(SupabaseConstants.adminImpersonationSessionsTable)
        .select(
          'id, actor_user_id, target_user_id, ticket_id, reason, '
          'started_at, ended_at, expires_at, status',
        );
    if (activeOnly) {
      query = query.eq('status', 'active');
    }

    final rows = await query.order('started_at', ascending: false).limit(limit);
    return (rows as List)
        .map(
          (row) => AdminImpersonationSession(
            id: row['id'] as int? ?? 0,
            actorUserId: row['actor_user_id'] as String? ?? '',
            targetUserId: row['target_user_id'] as String? ?? '',
            ticketId: row['ticket_id'] as String? ?? '',
            reason: row['reason'] as String? ?? '',
            startedAt:
                DateTime.tryParse(row['started_at'] as String? ?? '') ??
                DateTime.now().toUtc(),
            endedAt: DateTime.tryParse(row['ended_at'] as String? ?? ''),
            expiresAt:
                DateTime.tryParse(row['expires_at'] as String? ?? '') ??
                DateTime.now().toUtc(),
            status: row['status'] as String? ?? 'active',
          ),
        )
        .toList();
  }

  Future<void> startImpersonationSession({
    required String targetUserId,
    required String ticketId,
    required String reason,
    int durationMinutes = 30,
  }) async {
    final actor = _supabaseService.currentUser;
    final client = _supabaseService.clientOrNull;
    if (actor == null || client == null) return;

    // Security Enhancement: Ensure there is an approved request for this impersonation
    final approvalCheck = await client
        .from(SupabaseConstants.adminApprovalRequestsTable)
        .select('id')
        .eq('action_type', 'impersonate_user')
        .eq('status', 'approved')
        .eq('payload->>target_user_id', targetUserId)
        .maybeSingle();

    if (approvalCheck == null) {
      throw StateError(
        'Security Violation: Impersonation session can only be started for approved requests.',
      );
    }

    final now = DateTime.now().toUtc();
    final expiresAt = now.add(Duration(minutes: durationMinutes));
    final inserted = await client
        .from(SupabaseConstants.adminImpersonationSessionsTable)
        .insert({
          'actor_user_id': actor.id,
          'target_user_id': targetUserId,
          'ticket_id': ticketId.trim(),
          'reason': reason.trim(),
          'started_at': now.toIso8601String(),
          'expires_at': expiresAt.toIso8601String(),
          'status': 'active',
        })
        .select('id')
        .single();
    final sessionId = inserted['id'] as int? ?? 0;
    if (sessionId > 0) {
      await client
          .from(SupabaseConstants.adminImpersonationTelemetryTable)
          .insert({
            'session_id': sessionId,
            'actor_user_id': actor.id,
            'target_user_id': targetUserId,
            'event_type': 'started',
            'event_message': reason,
            'metadata': {
              'ticket_id': ticketId,
              'duration_minutes': durationMinutes,
            },
          });
    }

    await _writeAudit(
      action: 'start_impersonation',
      targetUserId: targetUserId,
      reason: 'ticket_id=$ticketId, duration_minutes=$durationMinutes',
      metadata: {'reason': reason},
    );
  }

  Future<void> endImpersonationSession({
    required int sessionId,
    required String targetUserId,
    String reason = 'manual_end',
  }) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return;

    await client
        .from(SupabaseConstants.adminImpersonationSessionsTable)
        .update({
          'status': 'ended',
          'ended_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', sessionId)
        .eq('status', 'active');
    final actor = _supabaseService.currentUser;
    if (actor != null) {
      await client
          .from(SupabaseConstants.adminImpersonationTelemetryTable)
          .insert({
            'session_id': sessionId,
            'actor_user_id': actor.id,
            'target_user_id': targetUserId,
            'event_type': 'ended',
            'event_message': reason,
          });
    }
    await _writeAudit(
      action: 'end_impersonation',
      targetUserId: targetUserId,
      reason: 'session_id=$sessionId, reason=$reason',
    );
  }

  Future<void> revokeImpersonationSession({
    required int sessionId,
    required String targetUserId,
    String reason = 'manual_revoke',
  }) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return;

    await client.rpc(
      'admin_revoke_impersonation_session',
      params: {'session_id': sessionId, 'revoke_reason': reason},
    );
    await _writeAudit(
      action: 'revoke_impersonation',
      targetUserId: targetUserId,
      reason: 'session_id=$sessionId, reason=$reason',
    );
  }

  Future<List<AdminImpersonationTelemetry>> fetchImpersonationTelemetry({
    required int sessionId,
    int limit = 100,
  }) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return const [];

    final rows = await client
        .from(SupabaseConstants.adminImpersonationTelemetryTable)
        .select(
          'id, session_id, actor_user_id, target_user_id, event_type, '
          'event_message, created_at',
        )
        .eq('session_id', sessionId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List)
        .map(
          (row) => AdminImpersonationTelemetry(
            id: row['id'] as int? ?? 0,
            sessionId: row['session_id'] as int? ?? 0,
            actorUserId: row['actor_user_id'] as String? ?? '',
            targetUserId: row['target_user_id'] as String? ?? '',
            eventType: row['event_type'] as String? ?? 'unknown',
            eventMessage: row['event_message'] as String? ?? '',
            createdAt:
                DateTime.tryParse(row['created_at'] as String? ?? '') ??
                DateTime.now().toUtc(),
          ),
        )
        .toList();
  }

  Future<void> _queueApprovedAction({
    required String actionType,
    required Map<String, dynamic> payload,
    required String approvedByUserId,
  }) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return;

    if (actionType == 'delete_account' ||
        actionType == 'enforce_mfa' ||
        actionType == 'signout_user') {
      final targetUserId = payload['target_user_id'] as String? ?? '';
      await client.from(SupabaseConstants.adminBulkJobsTable).insert({
        'actor_user_id': approvedByUserId,
        'job_type': actionType,
        'payload': payload,
        'status': 'pending',
        'summary': 'Approved action queued: $actionType ($targetUserId)',
      });
    }
  }

  Future<List<AdminBulkJob>> fetchBulkJobs({
    String? status,
    int limit = 100,
  }) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return const [];

    var query = client
        .from(SupabaseConstants.adminBulkJobsTable)
        .select(
          'id, actor_user_id, job_type, payload, status, summary, '
          'attempt_count, max_attempts, last_error, started_at, finished_at, '
          'worker_id, created_at, updated_at',
        );
    if (status != null && status.trim().isNotEmpty) {
      query = query.eq('status', status.trim());
    }
    final rows = await query.order('created_at', ascending: false).limit(limit);
    return (rows as List).map((row) {
      final payloadRaw = row['payload'];
      final payload = payloadRaw is Map
          ? Map<String, dynamic>.from(payloadRaw)
          : const <String, dynamic>{};
      return AdminBulkJob(
        id: row['id'] as int? ?? 0,
        actorUserId: row['actor_user_id'] as String? ?? '',
        jobType: row['job_type'] as String? ?? 'unknown',
        payload: payload,
        status: row['status'] as String? ?? 'pending',
        summary: row['summary'] as String? ?? '',
        attemptCount: row['attempt_count'] as int? ?? 0,
        maxAttempts: row['max_attempts'] as int? ?? 0,
        lastError: row['last_error'] as String? ?? '',
        startedAt: DateTime.tryParse(row['started_at'] as String? ?? ''),
        finishedAt: DateTime.tryParse(row['finished_at'] as String? ?? ''),
        workerId: row['worker_id'] as String?,
        createdAt:
            DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now().toUtc(),
        updatedAt:
            DateTime.tryParse(row['updated_at'] as String? ?? '') ??
            DateTime.now().toUtc(),
      );
    }).toList();
  }

  Future<void> createBulkJob({
    required String jobType,
    required Map<String, dynamic> payload,
    required String summary,
  }) async {
    final actor = _supabaseService.currentUser;
    final client = _supabaseService.clientOrNull;
    if (actor == null || client == null) return;

    await client.from(SupabaseConstants.adminBulkJobsTable).insert({
      'actor_user_id': actor.id,
      'job_type': jobType,
      'payload': payload,
      'status': 'pending',
      'summary': summary,
    });
    final targetUserId = payload['target_user_id'] as String? ?? actor.id;
    await _writeAudit(
      action: 'create_bulk_job',
      targetUserId: targetUserId,
      reason: 'job_type=$jobType, summary=$summary',
      metadata: payload,
    );
  }

  Future<void> retryBulkJob({
    required int jobId,
    required String reason,
  }) async {
    final actor = _supabaseService.currentUser;
    final client = _supabaseService.clientOrNull;
    if (actor == null || client == null) return;

    final row = await client
        .from(SupabaseConstants.adminBulkJobsTable)
        .select('payload, job_type')
        .eq('id', jobId)
        .maybeSingle();
    if (row == null) return;

    await client
        .from(SupabaseConstants.adminBulkJobsTable)
        .update({
          'status': 'pending',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', jobId);

    final payloadRaw = row['payload'];
    final payload = payloadRaw is Map
        ? Map<String, dynamic>.from(payloadRaw)
        : const <String, dynamic>{};
    final targetUserId = payload['target_user_id'] as String? ?? actor.id;
    await _writeAudit(
      action: 'retry_bulk_job',
      targetUserId: targetUserId,
      reason: 'job_id=$jobId, reason=$reason',
      metadata: {'job_type': row['job_type'], 'payload': payload},
    );
  }

  Future<void> cancelBulkJob({
    required int jobId,
    required String reason,
  }) async {
    final actor = _supabaseService.currentUser;
    final client = _supabaseService.clientOrNull;
    if (actor == null || client == null) return;

    final row = await client
        .from(SupabaseConstants.adminBulkJobsTable)
        .select('payload, job_type')
        .eq('id', jobId)
        .maybeSingle();
    if (row == null) return;

    await client
        .from(SupabaseConstants.adminBulkJobsTable)
        .update({
          'status': 'cancelled',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', jobId)
        .inFilter('status', ['pending', 'running', 'failed']);

    final payloadRaw = row['payload'];
    final payload = payloadRaw is Map
        ? Map<String, dynamic>.from(payloadRaw)
        : const <String, dynamic>{};
    final targetUserId = payload['target_user_id'] as String? ?? actor.id;
    await _writeAudit(
      action: 'cancel_bulk_job',
      targetUserId: targetUserId,
      reason: 'job_id=$jobId, reason=$reason',
      metadata: {'job_type': row['job_type'], 'payload': payload},
    );
  }

  Future<Map<String, dynamic>> exportComplianceSnapshot({
    int days = 30,
    int limitPerTable = 300,
  }) async {
    final client = _supabaseService.clientOrNull;
    final actor = _supabaseService.currentUser;
    if (client == null || actor == null) return const {};

    final since = DateTime.now().toUtc().subtract(Duration(days: days));
    final sinceIso = since.toIso8601String();

    final auditRows = await client
        .from(SupabaseConstants.adminAuditLogsTable)
        .select(
          'id, actor_user_id, target_user_id, action, reason, metadata, created_at',
        )
        .gte('created_at', sinceIso)
        .order('created_at', ascending: false)
        .limit(limitPerTable);
    final approvalRows = await client
        .from(SupabaseConstants.adminApprovalRequestsTable)
        .select(
          'id, requested_by, action_type, reason, status, approved_by, '
          'approved_at, rejected_by, rejected_at, created_at',
        )
        .gte('created_at', sinceIso)
        .order('created_at', ascending: false)
        .limit(limitPerTable);
    final impersonationRows = await client
        .from(SupabaseConstants.adminImpersonationSessionsTable)
        .select(
          'id, actor_user_id, target_user_id, ticket_id, reason, '
          'started_at, ended_at, expires_at, status',
        )
        .gte('started_at', sinceIso)
        .order('started_at', ascending: false)
        .limit(limitPerTable);
    final bulkRows = await client
        .from(SupabaseConstants.adminBulkJobsTable)
        .select(
          'id, actor_user_id, job_type, status, summary, created_at, updated_at',
        )
        .gte('created_at', sinceIso)
        .order('created_at', ascending: false)
        .limit(limitPerTable);

    return {
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'generated_by': actor.id,
      'window_days': days,
      'since': sinceIso,
      'counts': {
        'audit_logs': (auditRows as List).length,
        'approval_requests': (approvalRows as List).length,
        'impersonation_sessions': (impersonationRows as List).length,
        'bulk_jobs': (bulkRows as List).length,
      },
      'audit_logs': auditRows,
      'approval_requests': approvalRows,
      'impersonation_sessions': impersonationRows,
      'bulk_jobs': bulkRows,
    };
  }

  Future<int> assignApprovalOwners({int slaHours = 24}) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return 0;
    final result = await client.rpc(
      'admin_assign_approval_owners',
      params: {'default_owner': null, 'sla_hours': slaHours},
    );
    if (result is int) return result;
    return int.tryParse(result.toString()) ?? 0;
  }

  Future<int> enqueueSlaEscalations({
    int overdueHours = 24,
    String channel = 'webhook',
  }) async {
    final client = _supabaseService.clientOrNull;
    if (client == null) return 0;
    final result = await client.rpc(
      'admin_enqueue_sla_escalation_notifications',
      params: {'overdue_hours': overdueHours, 'channel': channel},
    );
    if (result is int) return result;
    return int.tryParse(result.toString()) ?? 0;
  }

  Future<AdminComplianceArchive?> exportSignedComplianceArchive({
    int days = 30,
    String format = 'json',
  }) async {
    final client = _supabaseService.clientOrNull;
    final actor = _supabaseService.currentUser;
    if (client == null || actor == null) return null;

    try {
      final response = await client.functions.invoke(
        'admin-compliance-export',
        body: {'days': days, 'format': format, 'actorUserId': actor.id},
      );
      final data = response.data;
      if (data is! Map) return null;
      final map = Map<String, dynamic>.from(data);
      final base64Content = map['contentBase64'] as String? ?? '';
      if (base64Content.isEmpty) return null;
      final content = Uint8List.fromList(base64Decode(base64Content));
      return AdminComplianceArchive(
        fileName: map['fileName'] as String? ?? 'admin_compliance.$format',
        mimeType: map['mimeType'] as String? ?? 'application/octet-stream',
        content: content,
        signature: map['signature'] as String? ?? '',
        checksumSha256: map['checksumSha256'] as String? ?? '',
        windowDays: map['windowDays'] as int? ?? days,
        format: map['format'] as String? ?? format,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeAudit({
    required String action,
    required String targetUserId,
    required String reason,
    Map<String, dynamic> metadata = const {},
  }) async {
    final actor = _supabaseService.currentUser;
    final client = _supabaseService.clientOrNull;
    if (actor == null || client == null) return;

    await client.from(SupabaseConstants.adminAuditLogsTable).insert({
      'actor_user_id': actor.id,
      'target_user_id': targetUserId,
      'action': action,
      'reason': reason,
      'metadata': metadata,
    });
  }
}
