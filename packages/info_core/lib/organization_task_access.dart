part of 'info_core.dart';

extension OwnerOrganizationTasks on OwnerAccess {
  List<OrganizationTask> get organizationTasks =>
      _service._repository.organizationTasks;
  OrganizationTaskState organizationState(OrganizationTask task) {
    if (task.state != OrganizationTaskState.active &&
        task.state != OrganizationTaskState.pending) {
      return task.state;
    }
    if (!_service._clock().isBefore(task.expiresAt)) {
      _service._expiredOrganizations.add(task.id);
    }
    if (_service._expiredOrganizations.contains(task.id)) {
      return OrganizationTaskState.expired;
    }
    if (!_service._sessionBindings.entries.any(
      (e) => e.value == task.sessionBinding && _service._sessionActive(e.key),
    )) {
      return OrganizationTaskState.cancelled;
    }
    return task.state;
  }

  bool organizationNeedsRenewal(OrganizationTask task) =>
      organizationState(task) == OrganizationTaskState.expired ||
      organizationState(task) == OrganizationTaskState.cancelled;

  Future<void> approveOrganization(String id, List<String> selected) =>
      _serialize(() async {
        final task = _organization(id);
        if (organizationState(task) != OrganizationTaskState.pending) {
          throw const AccessFailure('invalid_request');
        }
        final ids = selected.toSet();
        if (ids.isEmpty ||
            ids.length != selected.length ||
            ids.any(
              (id) =>
                  !task.itemVersions.containsKey(id) ||
                  !information.any((i) => i.id == id),
            )) {
          throw const AccessFailure('invalid_scope');
        }
        final now = _service._clock();
        await _service._repository.saveOrganizationTask(
          task.withState(
            OrganizationTaskState.active,
            approvedAt: now,
            expiresAt: now.add(const Duration(minutes: 30)),
            autoApply: true,
            itemVersions: {
              for (final item in information.where((i) => ids.contains(i.id)))
                item.id: item.version,
            },
          ),
        );
      });
  Future<void> denyOrganization(String id) => _serialize(() async {
    final task = _organization(id);
    if (organizationState(task) != OrganizationTaskState.pending) {
      throw const AccessFailure('invalid_request');
    }
    await _service._repository.saveOrganizationTask(
      task.withState(OrganizationTaskState.rejected),
    );
  });
  OrganizationTask _organization(String id) {
    if (_service._closed) throw const AccessFailure('service_unavailable');
    final found = organizationTasks.where((t) => t.id == id);
    if (found.isEmpty) throw const AccessFailure('unauthorized');
    return found.single;
  }

  Future<void> cancelOrganization(String id) => _serialize(() async {
    final task = _organization(id);
    if (task.state != OrganizationTaskState.active &&
        task.state != OrganizationTaskState.pending) {
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
    await _applyOrganization(task);
  });

  Future<void> _applyOrganization(
    OrganizationTask task, {
    void Function()? validate,
  }) async {
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
      validate: validate,
    );
  }
}

extension AgentOrganizationTasks on AgentAccess {
  Future<OrganizationTask> requestOrganization(
    String session,
    String purpose,
    List<String> itemIds, {
    String agentName = '',
  }) => _service.owner._serialize(() async {
    _service._requireSession(session);
    final ids = itemIds.toSet();
    if (purpose.trim().isEmpty ||
        purpose.length > 2000 ||
        agentName.length > 200 ||
        ids.isEmpty ||
        ids.length > 200 ||
        ids.length != itemIds.length ||
        ids.any((id) => !_service.owner.information.any((i) => i.id == id))) {
      throw const AccessFailure('invalid_request');
    }
    final binding = _service._sessionBindings[session]!;
    if (_service.owner.organizationTasks
            .where(
              (t) =>
                  t.sessionBinding == binding &&
                  [
                    OrganizationTaskState.pending,
                    OrganizationTaskState.active,
                  ].contains(_service.owner.organizationState(t)),
            )
            .length >=
        20) {
      throw const AccessFailure('proposal_limit');
    }
    final now = _service._clock();
    final task = OrganizationTask(
      id: _service._secret(),
      sessionBinding: binding,
      chatLabel: _service._sessions[session]!,
      purpose: purpose.trim(),
      agentName: agentName.trim(),
      createdAt: now,
      expiresAt: now.add(_service._requestLifetime),
      state: OrganizationTaskState.pending,
      itemVersions: {
        for (final item in _service.owner.information.where(
          (i) => ids.contains(i.id),
        ))
          item.id: item.version,
      },
    );
    await _service._repository.saveOrganizationTask(task);
    if (!_service._closed) _service._submitted.add(task.id);
    return task;
  });
  OrganizationTask _boundOrganization(String session, String id) {
    _service._requireSession(session);
    final task = _service.owner._organization(id);
    if (task.sessionBinding != _service._sessionBindings[session]) {
      throw const AccessFailure('unauthorized');
    }
    return task;
  }

  OrganizationTask _organizationTask(String session, String id) {
    final task = _boundOrganization(session, id);
    final state = _service.owner.organizationState(task);
    if (state != OrganizationTaskState.active) throw AccessFailure(state.name);
    return task;
  }

  Map<String, Object?> organizationStatus(String session, String id) {
    final task = _boundOrganization(session, id);
    return {
      'status': _service.owner.organizationState(task).name,
      'taskId': task.id,
      'itemCount': task.itemVersions.length,
      'expiresAt': task.expiresAt.toUtc().toIso8601String(),
      'autoApply': task.autoApply,
    };
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
            'status': _service.owner.organizationState(task).name,
            'expiresAt': task.expiresAt.toUtc().toIso8601String(),
          },
    ];
  }

  Future<Map<String, Object?>> organizationMetadata(
    String session,
    String id,
  ) => _service.owner._serialize(() async {
    final task = _organizationTask(session, id);
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
    final task = _organizationTask(session, id);
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
    final proposed = task.withState(
      OrganizationTaskState.proposed,
      changes: changes,
    );
    if (task.autoApply) {
      await _service.owner._applyOrganization(
        proposed,
        validate: () => _organizationTask(session, id),
      );
    } else {
      await _service._repository.saveOrganizationTask(proposed);
    }
  });
}
