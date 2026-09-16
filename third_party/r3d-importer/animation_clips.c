/* Rune extension: import the first clip of an animation-only file against
 * an existing R3D skeleton. Included after the patched r3d_importer.c so the
 * private bone-map layout and Assimp import policy stay identical.
 * Rune code is licensed under the repository's zlib license.
 */

static const struct aiNode* find_animation_node(const struct aiNode* node, const char* name)
{
    if (!node) return NULL;
    if (strcmp(node->mName.data, name) == 0) return node;
    for (unsigned int i = 0; i < node->mNumChildren; i++) {
        const struct aiNode* found = find_animation_node(node->mChildren[i], name);
        if (found) return found;
    }
    return NULL;
}

bool Rune_AppendAnimation(R3D_AnimationLib* library, const char* path,
                          const R3D_Skeleton* skeleton, const char* name)
{
    if (!library || !path || !name || !name[0] || strlen(name) >= 32 ||
        !skeleton || !skeleton->bones || skeleton->boneCount <= 0) return false;
    if (R3D_GetAnimationIndex(*library, name) >= 0) return false;

    struct aiPropertyStore* properties = create_import_properties();
    if (!properties) return false;
    aiSetImportPropertyInteger(properties, AI_CONFIG_IMPORT_NO_SKELETON_MESHES, 1);
    const struct aiScene* scene = aiImportFileExWithProperties(path, POST_PROCESS_PRESET_FAST, NULL, properties);
    aiReleasePropertyStore(properties);
    // Animation-only scenes may be flagged INCOMPLETE because they have no mesh.
    if (!scene || !scene->mRootNode || scene->mNumAnimations == 0) {
        aiReleaseImport(scene);
        return false;
    }

    R3D_Importer importer = {0};
    R3D_AnimationLib imported = {0};
    struct aiNodeAnim** channels = NULL;
    bool success = false;
    importer.bones.array = RL_CALLOC(skeleton->boneCount, sizeof(r3d_importer_bone_entry_t));
    if (!importer.bones.array) goto cleanup;
    for (int i = 0; i < skeleton->boneCount; i++) {
        const char* boneName = skeleton->bones[i].name;
        // This is joint-name mapping for the same rig, not skeleton retargeting.
        if (!find_animation_node(scene->mRootNode, boneName)) goto cleanup;
        r3d_importer_bone_entry_t* duplicate = NULL;
        HASH_FIND_STR(importer.bones.head, boneName, duplicate);
        if (duplicate) goto cleanup;
        r3d_importer_bone_entry_t* entry = &importer.bones.array[i];
        strncpy(entry->name, boneName, sizeof(entry->name) - 1);
        entry->index = i;
        HASH_ADD_STR(importer.bones.head, name, entry);
        importer.bones.count++;
    }

    // Keep only channels belonging to target joints. A skinless export often
    // also animates unweighted finger tips, which are absent from the mesh rig.
    struct aiAnimation animation = *scene->mAnimations[0];
    channels = RL_MALLOC(animation.mNumChannels * sizeof(*channels));
    if (!channels) goto cleanup;
    unsigned int count = 0;
    for (unsigned int i = 0; i < animation.mNumChannels; i++) {
        if (r3d_importer_get_bone_index(&importer, animation.mChannels[i]->mNodeName.data) >= 0) {
            channels[count++] = animation.mChannels[i];
        }
    }
    if (count == 0) goto cleanup;
    animation.mChannels = channels;
    animation.mNumChannels = count;
    struct aiAnimation* animationPtr = &animation;
    struct aiScene filtered = *scene;
    filtered.mAnimations = &animationPtr;
    filtered.mNumAnimations = 1;
    importer.scene = &filtered;
    imported = R3D_LoadAnimationLibFromImporter(&importer);
    if (imported.count != 1) goto cleanup;

    R3D_Animation* combined = RL_REALLOC(library->animations, (library->count + 1) * sizeof(*combined));
    if (!combined) goto cleanup;
    library->animations = combined;
    combined[library->count] = imported.animations[0];
    memset(combined[library->count].name, 0, sizeof(combined[library->count].name));
    strcpy(combined[library->count].name, name);
    library->count++;
    // Transfer the copied keyframe tracks, retaining only the combined array.
    RL_FREE(imported.animations);
    imported = (R3D_AnimationLib){0};
    success = true;

cleanup:
    R3D_UnloadAnimationLib(imported);
    RL_FREE(channels);
    HASH_CLEAR(hh, importer.bones.head);
    RL_FREE(importer.bones.array);
    aiReleaseImport(scene);
    return success;
}
