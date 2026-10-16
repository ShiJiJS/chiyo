part of 'info_core.dart';

extension OwnerOrganizationTasks on OwnerAccess {
  List<OrganizationAgent> get organizationAgents => List.unmodifiable([
    for (final e in _service._sessions.entries)
      if (_service._sessionActive(e.key))
        OrganizationAgent(_service._sessionBindings[e.key]!, e.value),
  ]);
  List<OrganizationTask> get organizationTasks =>
      _service._repository.organizationTasks;
  bool organizationConnected(OrganizationTask task) =>
      organizationAgents.any((a) => a.id == task.sessionBinding);
  bool organizationNeedsRenewal(OrganizationTask task) {
    if (task.state != OrganizationTaskState.active) return false;
    if (!_service._clock().isBefore(task.expiresAt)) {
      _service._expiredOrganizations.add(task.id);
    }
    return !organizationConnected(task) ||
        _service._expiredOrganizations.contains(task.id);
  }

  Future<OrganizationTask> startOrganizationTask(
    String agentId,
    List<String> itemIds, {
    String purpose = '整理资料的分类与标签',
  }) => _serialize(() async {
    if (_service._closed || !organizationAgents.any((a) => a.id == agentId)) {
      throw const AccessFailure('unauthorized');
    }
    final ids = itemIds.toSet();
    if (ids.isEmpty ||
        ids.length > 200 ||
        ids.length != itemIds.length ||
        purpose.trim().isEmpty ||
        purpose.length > 2000 ||
        ids.any((id) => !information.any((i) => i.id == id))) {
      throw const AccessFailure('invalid_request');
    }
    if (organizationTasks
            .where(
              (t) =>
                  t.state == OrganizationTaskState.active &&
                  t.sessionBinding == agentId &&
                  !organizationNeedsRenewal(t),
            )
            .length >=
        20) {
      throw const AccessFailure('proposal_limit');
    }
    final now = _service._clock();
    final task = OrganizationTask(
      id: _service._secret(),
      sessionBinding: agentId,
      chatLabel: organizationAgents
          .firstWhere((a) => a.id == agentId)
          .chatLabel,
      purpose: purpose.trim(),
      createdAt: now,
      expiresAt: now.add(const Duration(minutes: 30)),
      itemVersions: {
        for (final i in information.where((i) => ids.contains(i.id)))
          i.id: i.version,
      },
    );
    await _service._repository.saveOrganizationTask(task);
    return task;
  });
  OrganizationTask _organization(String id) {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    final found = organizationTasks.where((t) => t.id == id);
    if (found.isEmpty) throw const AccessFailure('unauthorized');
    return found.single;
  }

  Future<void> cancelOrganization(String id) => _serialize(() async {
    final task = _organization(id);
    if (task.state != OrganizationTaskState.active) {
      throw const AccessFailure('invalid_request');
    }
    await _service._repository.saveOrganizationTask(
      task.withState(OrganizationTaskState.cancelled),
    );
  });
  Future<void> rejectOrganization(String id) => _serialize(() async {
    final task = _organization(id);
    if (task.state != OrganizationTaskState.proposed) {
      throw const AccessFailure('invalid_request');
    }
    await _service._repository.saveOrganizationTask(
      task.withState(OrganizationTaskState.rejected),
    );
  });
  Future<void> confirmOrganization(String id) => _serialize(() async {
    final task = _organization(id);
    if (task.state == OrganizationTaskState.confirmed) return;
    if (task.state != OrganizationTaskState.proposed) {
      throw const AccessFailure('invalid_request');
    }
    if (task.changes.any(
      (c) => !information.any(
        (i) => i.id == c.itemId && i.version == c.baseVersion,
      ),
    )) {
      await _service._repository.saveOrganizationTask(
        task.withState(OrganizationTaskState.conflicted),
      );
      throw const AccessFailure('organization_conflict');
    }
    final organization = _OrganizationPlan(this);
    final changed = <InformationItem>[];
    final previous = <InformationRevision>[];
    final now = _service._clock();
    for (final change in task.changes) {
      final old = information.firstWhere((i) => i.id == change.itemId);
      final location = organization.resolve(
        change.directoryId,
        change.tagIds,
        change.directoryName,
        change.tagNames,
      );
      changed.add(
        InformationItem(
          old.id,
          old.name,
          old.description,
          old.version + 1,
          old.fields,
          directoryId: location.$1,
          tagIds: location.$2,
          createdAt: old.createdAt,
          modifiedAt: now,
        ),
      );
      previous.add(InformationRevision(old, now));
    }
    await _service._repository.confirmOrganizationTask(
      task.withState(OrganizationTaskState.confirmed),
      changed,
      previous,
      newDirectories: organization.newDirectories,
      newTags: organization.newTags,
    );
  });
}

extension AgentOrganizationTasks on AgentAccess {
  Future<OrganizationTask> _organizationTask(String session, String id) async {
    _service._requireSession(session);
    final task = _service.owner._organization(id);
    if (task.sessionBinding != _service._sessionBindings[session]) {
      throw const AccessFailure('unauthorized');
    }
    if (task.state != OrganizationTaskState.active) {
      throw AccessFailure(task.state.name);
    }
    if (_service._expiredOrganizations.contains(id) ||
        !_service._clock().isBefore(task.expiresAt)) {
      _service._expiredOrganizations.add(id);
      await _service._repository.saveOrganizationTask(
        task.withState(OrganizationTaskState.expired),
      );
      throw const AccessFailure('expired');
    }
    return task;
  }

  List<Map<String, Object?>> organizationTasks(String session) {
    _service._requireSession(session);
    return [
      for (final task in _service._repository.organizationTasks)
        if (task.sessionBinding == _service._sessionBindings[session])
          {
            'taskId': task.id,
            'purpose': task.purpose,
            'itemCount': task.itemVersions.length,
            'status': _service.owner.organizationNeedsRenewal(task)
                ? 'expired'
                : task.state.name,
            'expiresAt': task.expiresAt.toUtc().toIso8601String(),
          },
    ];
  }

  Future<Map<String, Object?>> organizationMetadata(
    String session,
    String id,
  ) => _service.owner._serialize(() async {
    final task = await _organizationTask(session, id);
    _service._requireSession(session);
    if (_service.owner.organizationNeedsRenewal(task)) {
      throw const AccessFailure('expired');
    }
    final scoped = _service.owner.information
        .where((i) => task.itemVersions.containsKey(i.id))
        .toList();
    if (scoped.length != task.itemVersions.length ||
        scoped.any((i) => i.version != task.itemVersions[i.id])) {
      await _service._repository.saveOrganizationTask(
        task.withState(OrganizationTaskState.conflicted),
      );
      throw const AccessFailure('organization_conflict');
    }
    return {
      'status': 'ok',
      'taskId': task.id,
      'purpose': task.purpose,
      'items': [
        for (final item in scoped)
          {
            'id': item.id,
            'version': item.version,
            'name': item.name,
            'description': item.description,
            'directoryId': item.directoryId,
            'tagIds': item.tagIds,
          },
      ],
      'directories': [
        for (final d in _service.owner.directories)
          {'id': d.id, 'name': d.name, 'parentId': d.parentId},
      ],
      'tags': [
        for (final t in _service.owner.tags) {'id': t.id, 'name': t.name},
      ],
    };
  });
  Future<void> submitOrganization(
    String session,
    String id,
    List<OrganizationChange> changes,
  ) => _service.owner._serialize(() async {
    final task = await _organizationTask(session, id);
    _service._requireSession(session);
    if (_service.owner.organizationNeedsRenewal(task)) {
      throw const AccessFailure('expired');
    }
    if (changes.isEmpty ||
        changes.length > 200 ||
        changes.map((c) => c.itemId).toSet().length != changes.length ||
        utf8
                .encode(jsonEncode(changes.map((c) => c.toJson()).toList()))
                .length >
            240000 ||
        changes.any(
          (c) =>
              task.itemVersions[c.itemId] != c.baseVersion ||
              c.directoryName.length > 200 ||
              (c.directoryId?.length ?? 0) > 200 ||
              c.tagIds.length + c.tagNames.length > 100 ||
              c.tagIds.any((s) => s.length > 200) ||
              c.tagNames.any((s) => s.length > 200),
        )) {
      throw const AccessFailure('invalid_proposal');
    }
    // Validate all organization references before retaining a proposal. No writes yet.
    final labels = _OrganizationPlan(_service.owner);
    for (final change in changes) {
      labels.resolve(
        change.directoryId,
        change.tagIds,
        change.directoryName,
        change.tagNames,
      );
    }
    await _service._repository.saveOrganizationTask(
      task.withState(OrganizationTaskState.proposed, changes: changes),
    );
  });
}
