import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/models/admin_account_summary.dart';
import 'package:recall_app/models/admin_approval_request.dart';
import 'package:recall_app/models/admin_audit_entry.dart';
import 'package:recall_app/models/admin_bulk_job.dart';
import 'package:recall_app/models/admin_community_report.dart';
import 'package:recall_app/models/admin_impersonation_session.dart';
import 'package:recall_app/models/admin_impersonation_telemetry.dart';
import 'package:recall_app/models/admin_risk_alert.dart';
import 'package:recall_app/providers/auth_provider.dart';
import 'package:recall_app/services/admin_service.dart';

final adminServiceProvider = Provider<AdminService>((ref) {
  final supabase = ref.watch(supabaseServiceProvider);
  return AdminService(supabaseService: supabase);
});

final adminAccessProvider = FutureProvider<bool>((ref) async {
  // Watch auth state so the provider re-evaluates on login/logout.
  ref.watch(authStateProvider);
  final adminService = ref.watch(adminServiceProvider);
  return adminService.hasAdminAccess();
});

final adminAccountsProvider =
    FutureProvider.family<List<AdminAccountSummary>, String>((
      ref,
      query,
    ) async {
      final adminService = ref.watch(adminServiceProvider);
      return adminService.fetchAccounts(query: query);
    });

final adminAuditProvider = FutureProvider<List<AdminAuditEntry>>((ref) async {
  final adminService = ref.watch(adminServiceProvider);
  return adminService.fetchAuditEntries(limit: 100);
});

final adminCommunityReportsProvider =
    FutureProvider<List<AdminCommunityReport>>((ref) async {
      final adminService = ref.watch(adminServiceProvider);
      return adminService.fetchCommunityReports();
    });

final adminRiskAlertsProvider = FutureProvider<List<AdminRiskAlert>>((
  ref,
) async {
  final adminService = ref.watch(adminServiceProvider);
  return adminService.fetchRiskAlerts(limit: 100);
});

final adminApprovalRequestsProvider =
    FutureProvider.family<List<AdminApprovalRequest>, String?>((
      ref,
      status,
    ) async {
      final adminService = ref.watch(adminServiceProvider);
      return adminService.fetchApprovalRequests(status: status, limit: 100);
    });

final adminImpersonationSessionsProvider =
    FutureProvider.family<List<AdminImpersonationSession>, bool>((
      ref,
      activeOnly,
    ) async {
      final adminService = ref.watch(adminServiceProvider);
      return adminService.fetchImpersonationSessions(
        activeOnly: activeOnly,
        limit: 100,
      );
    });

final adminBulkJobsProvider =
    FutureProvider.family<List<AdminBulkJob>, String?>((ref, status) async {
      final adminService = ref.watch(adminServiceProvider);
      return adminService.fetchBulkJobs(status: status, limit: 100);
    });

final adminImpersonationTelemetryProvider =
    FutureProvider.family<List<AdminImpersonationTelemetry>, int>((
      ref,
      sessionId,
    ) async {
      final adminService = ref.watch(adminServiceProvider);
      return adminService.fetchImpersonationTelemetry(
        sessionId: sessionId,
        limit: 100,
      );
    });
