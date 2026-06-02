class AdminCommunityReport {
  final String publicSetId;
  final String title;
  final String authorName;
  final String visibility;
  final String moderationStatus;
  final String moderationReason;
  final int pendingReportCount;
  final DateTime? latestReportAt;

  const AdminCommunityReport({
    required this.publicSetId,
    required this.title,
    required this.authorName,
    required this.visibility,
    required this.moderationStatus,
    required this.moderationReason,
    required this.pendingReportCount,
    required this.latestReportAt,
  });

  factory AdminCommunityReport.fromJson(Map<String, dynamic> json) {
    return AdminCommunityReport(
      publicSetId: json['public_set_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      authorName: json['author_name'] as String? ?? '',
      visibility: json['visibility'] as String? ?? 'public',
      moderationStatus: json['moderation_status'] as String? ?? 'approved',
      moderationReason: json['moderation_reason'] as String? ?? '',
      pendingReportCount: (json['pending_report_count'] as num?)?.toInt() ?? 0,
      latestReportAt: DateTime.tryParse(
        json['latest_report_at'] as String? ?? '',
      ),
    );
  }
}
